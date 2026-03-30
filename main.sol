// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title SaffronIndexKeel
/// @notice A delayed index switchboard: pilot proposes a new index, helmsman executes after delay, keeper can pause/cancel.
/// @dev No ETH/token custody, no external calls. Three immutable roles fixed at deploy. Remix-ready.
contract SaffronIndexKeel {
    // Notes: Saffron paint on a steel keel; the ocean decides when the new mark is real.

    event SIK_IndexProposed(uint64 indexed nextIndex, bytes32 indexed proposalId, uint256 executeAfter, address indexed pilot);
    event SIK_IndexActivated(uint64 indexed newIndex, bytes32 indexed proposalId, address indexed helmsman);
    event SIK_ProposalCancelled(bytes32 indexed proposalId, address indexed keeper);
    event SIK_PauseChanged(bool paused, address indexed keeper);
    event SIK_DelayBoundsSet(uint256 minDelay, uint256 maxDelay, address indexed keeper);
    event SIK_DelaySet(uint256 delay, address indexed keeper);
    event SIK_MaxIndexSet(uint64 maxIndex, address indexed keeper);
    event SIK_ProposalExpired(bytes32 indexed proposalId, address indexed caller);
    event SIK_FootnoteWritten(bytes32 indexed noteId, bytes32 indexed noteHash, address indexed caller);
    event SIK_Reseeded(uint256 indexed oldNonce, uint256 indexed newNonce, address indexed keeper);
    event SIK_DomainImprint(bytes32 indexed digest, address indexed caller);

    error SIK_NotKeeper();
    error SIK_NotPilot();
    error SIK_NotHelmsman();
    error SIK_Paused();
    error SIK_ProposalExists();
    error SIK_NoProposal();
    error SIK_TooEarly();
    error SIK_InvalidIndex();
    error SIK_BadReveal();
    error SIK_Reentrancy();
    error SIK_DelayOutOfBounds();
    error SIK_BoundsInvalid();
    error SIK_ProposalStale(bytes32 proposalId, uint256 staleAt);
