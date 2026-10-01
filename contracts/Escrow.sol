// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract Escrow is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 private constant BASIS_POINTS = 10_000;

    enum State {
        Created,
        Funded,
        InProgress,
        Completed,
        Disputed,
        Resolved,
        Cancelled
    }

    struct EscrowData {
        address buyer;
        address seller;
        IERC20 token;
        uint256 totalAmount;
        uint256 milestoneAmount;
        uint32 milestoneCount;
        uint32 completedMilestones;
        uint64 deadline;
        State state;
        uint256 releasedAmount;
        uint256 refundedAmount;
        bool milestoneSubmitted;
        bool milestoneApproved;
    }

    error ZeroAddress();
    error InvalidAmount();
    error InvalidMilestonePlan();
    error InvalidDeadline();
    error InvalidEscrowId(uint256 escrowId);
    error InvalidState(State currentState);
    error Unauthorized(address caller);
    error DeadlinePassed(uint256 deadline);
    error DeadlineNotPassed(uint256 deadline);
    error MilestoneNotSubmitted();
    error MilestoneAlreadySubmitted();
    error MilestoneNotApproved();
    error MilestoneAlreadyApproved();
    error InvalidSubmissionReference();
    error InvalidShare(uint256 shareBps);
    error NothingToWithdraw();
    error NothingToRefund();

    uint256 public nextEscrowId = 1;
    mapping(uint256 escrowId => EscrowData escrow) private escrows;
    mapping(uint256 escrowId => mapping(address user => uint256 amount)) private userContributions;
    mapping(uint256 escrowId => uint256 amount) public buyerRefundable;
    mapping(address token => mapping(address account => uint256 amount)) public claimable;
    mapping(uint256 escrowId => mapping(uint32 milestone => bytes32 submissionHash)) public submissionReferences;

    event EscrowCreated(
        uint256 indexed escrowId,
        address indexed buyer,
        address indexed seller,
        address token,
        uint256 totalAmount,
        uint32 milestoneCount,
        uint64 deadline
    );
    event EscrowFunded(uint256 indexed escrowId, address indexed buyer, uint256 amount);
    event EscrowAccepted(uint256 indexed escrowId, address indexed seller);
    event MilestoneSubmitted(uint256 indexed escrowId, uint32 indexed milestone, bytes32 submissionReference);
    event MilestoneApproved(uint256 indexed escrowId, uint32 indexed milestone, address indexed buyer);
    event PaymentReleased(uint256 indexed escrowId, address indexed seller, uint256 amount, uint32 completedMilestones);
    event DisputeRaised(uint256 indexed escrowId, address indexed raisedBy, bytes32 reasonHash);
    event DisputeResolved(
        uint256 indexed escrowId,
        address indexed arbitrator,
        uint256 sellerAmount,
        uint256 buyerAmount
    );
    event EscrowCancelled(uint256 indexed escrowId, address indexed buyer, uint256 refundableAmount);
    event RefundIssued(uint256 indexed escrowId, address indexed buyer, uint256 amount);
    event PaymentWithdrawn(address indexed token, address indexed account, uint256 amount);

    constructor() Ownable(msg.sender) {}

    function createEscrow(
        address seller,
        IERC20 token,
        uint256 totalAmount,
        uint256 milestoneAmount,
        uint32 milestoneCount,
        uint64 deadline
    ) external returns (uint256 escrowId) {
        if (seller == address(0) || address(token) == address(0)) revert ZeroAddress();
        if (seller == msg.sender) revert Unauthorized(msg.sender);
        if (totalAmount == 0 || milestoneAmount == 0 || milestoneCount == 0) revert InvalidAmount();
        if (milestoneAmount * milestoneCount != totalAmount) revert InvalidMilestonePlan();
        if (deadline <= block.timestamp) revert InvalidDeadline();

        escrowId = nextEscrowId++;
        escrows[escrowId] = EscrowData({
            buyer: msg.sender,
            seller: seller,
            token: token,
            totalAmount: totalAmount,
            milestoneAmount: milestoneAmount,
            milestoneCount: milestoneCount,
            completedMilestones: 0,
            deadline: deadline,
            state: State.Created,
            releasedAmount: 0,
            refundedAmount: 0,
            milestoneSubmitted: false,
            milestoneApproved: false
        });

        emit EscrowCreated(escrowId, msg.sender, seller, address(token), totalAmount, milestoneCount, deadline);
    }

    function fundEscrow(uint256 escrowId) external nonReentrant {
        EscrowData storage escrow = _getEscrow(escrowId);
        _requireBuyer(escrow);
        _requireState(escrow, State.Created);
        _requireBeforeDeadline(escrow);

        escrow.state = State.Funded;
        userContributions[escrowId][msg.sender] = escrow.totalAmount;
        escrow.token.safeTransferFrom(msg.sender, address(this), escrow.totalAmount);

        emit EscrowFunded(escrowId, msg.sender, escrow.totalAmount);
    }

    function acceptEscrow(uint256 escrowId) external {
        EscrowData storage escrow = _getEscrow(escrowId);
        _requireSeller(escrow);
        _requireState(escrow, State.Funded);
        _requireBeforeDeadline(escrow);

        escrow.state = State.InProgress;
        emit EscrowAccepted(escrowId, msg.sender);
    }

    function submitMilestone(uint256 escrowId, bytes32 submissionReference) external {
        EscrowData storage escrow = _getEscrow(escrowId);
        _requireSeller(escrow);
        _requireState(escrow, State.InProgress);
        _requireBeforeDeadline(escrow);
        if (escrow.milestoneSubmitted) revert MilestoneAlreadySubmitted();
        if (submissionReference == bytes32(0)) revert InvalidSubmissionReference();

        uint32 milestone = escrow.completedMilestones + 1;
        escrow.milestoneSubmitted = true;
        submissionReferences[escrowId][milestone] = submissionReference;
        emit MilestoneSubmitted(escrowId, milestone, submissionReference);
    }

    function approveMilestone(uint256 escrowId) external {
        EscrowData storage escrow = _getEscrow(escrowId);
        _requireBuyer(escrow);
        _requireState(escrow, State.InProgress);
        if (!escrow.milestoneSubmitted) revert MilestoneNotSubmitted();
        if (escrow.milestoneApproved) revert MilestoneAlreadyApproved();

        escrow.milestoneApproved = true;
        emit MilestoneApproved(escrowId, escrow.completedMilestones + 1, msg.sender);
    }

    function releaseMilestone(uint256 escrowId) external {
        EscrowData storage escrow = _getEscrow(escrowId);
        _requireState(escrow, State.InProgress);
        if (!escrow.milestoneApproved) revert MilestoneNotApproved();

        uint256 amount = escrow.milestoneAmount;
        uint32 completedMilestones = escrow.completedMilestones + 1;
        escrow.completedMilestones = completedMilestones;
        escrow.releasedAmount += amount;
        escrow.milestoneSubmitted = false;
        escrow.milestoneApproved = false;
        claimable[address(escrow.token)][escrow.seller] += amount;

        if (completedMilestones == escrow.milestoneCount) {
            escrow.state = State.Completed;
        }

        emit PaymentReleased(escrowId, escrow.seller, amount, completedMilestones);
    }

    function raiseDispute(uint256 escrowId, bytes32 reasonHash) external {
        EscrowData storage escrow = _getEscrow(escrowId);
        _requireParticipant(escrow);
        if (escrow.state != State.Funded && escrow.state != State.InProgress) {
            revert InvalidState(escrow.state);
        }

        escrow.state = State.Disputed;
        emit DisputeRaised(escrowId, msg.sender, reasonHash);
    }

    function resolveDisputeForSeller(uint256 escrowId) external onlyOwner {
        _resolveDispute(escrowId, _getEscrow(escrowId).totalAmount - _getEscrow(escrowId).releasedAmount - _getEscrow(escrowId).refundedAmount, 0);
    }

    function resolveDisputeForBuyer(uint256 escrowId) external onlyOwner {
        _resolveDispute(escrowId, 0, getRemainingAmount(escrowId));
    }

    function resolveDisputeSplit(uint256 escrowId, uint16 sellerShareBps) external onlyOwner {
        if (sellerShareBps > BASIS_POINTS) revert InvalidShare(sellerShareBps);
        uint256 remainingAmount = getRemainingAmount(escrowId);
        uint256 sellerAmount = (remainingAmount * sellerShareBps) / BASIS_POINTS;
        _resolveDispute(escrowId, sellerAmount, remainingAmount - sellerAmount);
    }

    function cancelEscrow(uint256 escrowId) external {
        EscrowData storage escrow = _getEscrow(escrowId);
        _requireBuyer(escrow);
        if (
            escrow.state != State.Created && escrow.state != State.Funded &&
            (escrow.state != State.InProgress || block.timestamp <= escrow.deadline)
        ) {
            revert InvalidState(escrow.state);
        }
        if (escrow.state == State.InProgress && escrow.milestoneApproved) {
            revert InvalidState(escrow.state);
        }

        uint256 refundableAmount;
        if (escrow.state != State.Created) {
            refundableAmount = getRemainingAmount(escrowId);
            escrow.refundedAmount += refundableAmount;
            buyerRefundable[escrowId] += refundableAmount;
        }
        escrow.state = State.Cancelled;

        emit EscrowCancelled(escrowId, msg.sender, refundableAmount);
    }

    function refund(uint256 escrowId) external nonReentrant {
        EscrowData storage escrow = _getEscrow(escrowId);
        _requireBuyer(escrow);
        if (escrow.state != State.Cancelled && escrow.state != State.Resolved) {
            revert InvalidState(escrow.state);
        }

        uint256 amount = buyerRefundable[escrowId];
        if (amount == 0) revert NothingToRefund();
        buyerRefundable[escrowId] = 0;
        escrow.token.safeTransfer(escrow.buyer, amount);

        emit RefundIssued(escrowId, escrow.buyer, amount);
    }

    function withdraw(IERC20 token) external nonReentrant {
        uint256 amount = claimable[address(token)][msg.sender];
        if (amount == 0) revert NothingToWithdraw();

        claimable[address(token)][msg.sender] = 0;
        token.safeTransfer(msg.sender, amount);
        emit PaymentWithdrawn(address(token), msg.sender, amount);
    }

    function getEscrow(uint256 escrowId) external view returns (EscrowData memory) {
        return _getEscrow(escrowId);
    }

    function getUserContribution(uint256 escrowId, address user) external view returns (uint256) {
        _getEscrow(escrowId);
        return userContributions[escrowId][user];
    }

    function getRemainingAmount(uint256 escrowId) public view returns (uint256) {
        EscrowData storage escrow = _getEscrow(escrowId);
        return escrow.totalAmount - escrow.releasedAmount - escrow.refundedAmount;
    }

    function _resolveDispute(uint256 escrowId, uint256 sellerAmount, uint256 buyerAmount) private {
        EscrowData storage escrow = _getEscrow(escrowId);
        _requireState(escrow, State.Disputed);

        uint256 remainingAmount = getRemainingAmount(escrowId);
        if (sellerAmount + buyerAmount != remainingAmount) revert InvalidAmount();

        escrow.releasedAmount += sellerAmount;
        escrow.refundedAmount += buyerAmount;
        escrow.state = State.Resolved;
        claimable[address(escrow.token)][escrow.seller] += sellerAmount;
        buyerRefundable[escrowId] += buyerAmount;

        emit DisputeResolved(escrowId, msg.sender, sellerAmount, buyerAmount);
    }

    function _getEscrow(uint256 escrowId) private view returns (EscrowData storage escrow) {
        escrow = escrows[escrowId];
        if (escrow.buyer == address(0)) revert InvalidEscrowId(escrowId);
    }

    function _requireBuyer(EscrowData storage escrow) private view {
        if (msg.sender != escrow.buyer) revert Unauthorized(msg.sender);
    }

    function _requireSeller(EscrowData storage escrow) private view {
        if (msg.sender != escrow.seller) revert Unauthorized(msg.sender);
    }

    function _requireParticipant(EscrowData storage escrow) private view {
        if (msg.sender != escrow.buyer && msg.sender != escrow.seller) revert Unauthorized(msg.sender);
    }

    function _requireState(EscrowData storage escrow, State expectedState) private view {
        if (escrow.state != expectedState) revert InvalidState(escrow.state);
    }

    function _requireBeforeDeadline(EscrowData storage escrow) private view {
        if (block.timestamp > escrow.deadline) revert DeadlinePassed(escrow.deadline);
    }
}