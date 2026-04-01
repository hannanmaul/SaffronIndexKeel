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
    error SIK_ProposalIdMismatch();
    error SIK_NoteZero();
    error SIK_NonceTooSmall();

    uint256 public constant SIK_REVISION = 2;
    uint256 public constant SIK_DEFAULT_DELAY = 18 hours;
    uint256 public constant SIK_DEFAULT_MIN_DELAY = 10 minutes;
    uint256 public constant SIK_DEFAULT_MAX_DELAY = 7 days;
    uint256 public constant SIK_PROPOSAL_TTL = 30 days;
    uint64 public constant SIK_DEFAULT_MAX_INDEX = 9_999_999;
    bytes32 public constant SIK_DOMAIN = keccak256("SaffronIndexKeel.v1");
    bytes32 public constant SIK_NOTE_DOMAIN = keccak256("SaffronIndexKeel.Footnote.v1");
    uint8 public constant SIK_HISTORY_SIZE = 24;
    uint8 public constant SIK_PROPOSAL_LOG_SIZE = 32;
    uint256 public constant SIK_MIN_SPACING_SECONDS = 60;

    address public immutable keeper;
    address public immutable pilot;
    address public immutable helmsman;

    bool private _paused;
    uint256 private _guard;
    uint64 private _index;
    uint256 private _nonce;

    bytes32 private _pendingId;
    uint64 private _pendingIndex;
    uint256 private _pendingExecuteAfter;
    uint256 private _lastDecisionAt;
    uint256 private _lastQueueAt;

    uint256 private _delay;
    uint256 private _minDelay;
    uint256 private _maxDelay;
    uint64 private _maxIndex;

    enum ProposalState {
        None,
        Queued,
        Activated,
        Cancelled,
        Expired
    }

    struct ProposalMeta {
        uint64 nextIndex;
        uint64 previousIndex;
        uint256 nonce;
        uint256 queuedAt;
        uint256 executeAfter;
        uint256 decidedAt;
        ProposalState state;
    }

    mapping(bytes32 => ProposalMeta) private _proposal;

    struct HistoryEntry {
        uint64 index;
        bytes32 proposalId;
        uint256 activatedAt;
        uint256 nonceAfter;
    }

    HistoryEntry[SIK_HISTORY_SIZE] private _history;
    uint256 private _historyHead;
    uint256 private _historyCount;

    bytes32[SIK_PROPOSAL_LOG_SIZE] private _proposalLog;
    uint256 private _proposalLogHead;
    uint256 private _proposalLogCount;

    mapping(bytes32 => bool) private _footnoteSeen;

    constructor() {
        keeper = 0x682fc77BF23878E0eD5E498dBb203183a571fab2;
        pilot = 0x52fBCBa65b0a18BB31f7465419c92a4b37Db7FD8;
        helmsman = 0xE83d24daCE06f576487755D475DE76df41f05112;

        _index = 101;
        _nonce = 1;
        _delay = SIK_DEFAULT_DELAY;
        _minDelay = SIK_DEFAULT_MIN_DELAY;
        _maxDelay = SIK_DEFAULT_MAX_DELAY;
        _maxIndex = SIK_DEFAULT_MAX_INDEX;
        _lastDecisionAt = block.timestamp;
        _lastQueueAt = 0;
    }

    modifier onlyKeeper() {
        if (msg.sender != keeper) revert SIK_NotKeeper();
        _;
    }

    modifier onlyPilot() {
        if (msg.sender != pilot) revert SIK_NotPilot();
        _;
    }

    modifier onlyHelmsman() {
        if (msg.sender != helmsman) revert SIK_NotHelmsman();
        _;
    }

    modifier whenLive() {
        if (_paused) revert SIK_Paused();
        _;
    }

    modifier nonReentrant() {
        if (_guard == 1) revert SIK_Reentrancy();
        _guard = 1;
        _;
        _guard = 0;
    }

    function setPaused(bool paused_) external onlyKeeper {
        _paused = paused_;
        emit SIK_PauseChanged(paused_, msg.sender);
    }

    function setDelayBounds(uint256 minDelay_, uint256 maxDelay_) external onlyKeeper {
        if (minDelay_ == 0 || maxDelay_ == 0 || minDelay_ > maxDelay_) revert SIK_BoundsInvalid();
        _minDelay = minDelay_;
        _maxDelay = maxDelay_;
        if (_delay < _minDelay || _delay > _maxDelay) revert SIK_DelayOutOfBounds();
        emit SIK_DelayBoundsSet(minDelay_, maxDelay_, msg.sender);
    }

    function setDelay(uint256 delay_) external onlyKeeper {
        if (delay_ < _minDelay || delay_ > _maxDelay) revert SIK_DelayOutOfBounds();
        _delay = delay_;
        emit SIK_DelaySet(delay_, msg.sender);
    }

    function setMaxIndex(uint64 maxIndex_) external onlyKeeper {
        if (maxIndex_ == 0) revert SIK_InvalidIndex();
        _maxIndex = maxIndex_;
        emit SIK_MaxIndexSet(maxIndex_, msg.sender);
    }

    function expireProposal() external nonReentrant {
        if (_pendingExecuteAfter == 0) revert SIK_NoProposal();
        ProposalMeta storage m = _proposal[_pendingId];
        if (m.state != ProposalState.Queued) revert SIK_NoProposal();
        if (block.timestamp < m.queuedAt + SIK_PROPOSAL_TTL) revert SIK_TooEarly();

        bytes32 pid = _pendingId;
        m.state = ProposalState.Expired;
        m.decidedAt = block.timestamp;
        _lastDecisionAt = block.timestamp;
        _clearPending();
        emit SIK_ProposalExpired(pid, msg.sender);
    }

    /// @notice Optional footnote log (content-addressed) for ops/audits; write-once per noteId.
    function writeFootnote(bytes32 noteId, bytes32 noteHash) external whenLive nonReentrant {
        if (noteId == bytes32(0) || noteHash == bytes32(0)) revert SIK_NoteZero();
        if (_footnoteSeen[noteId]) revert SIK_BadReveal();
        _footnoteSeen[noteId] = true;
        emit SIK_FootnoteWritten(noteId, keccak256(abi.encode(SIK_NOTE_DOMAIN, noteId, noteHash, block.chainid)), msg.sender);
    }

    /// @notice Keeper can reseed the nonce upward (one-way) for operational resets without changing roles.
    function reseedNonce(uint256 newNonce) external onlyKeeper nonReentrant {
        if (newNonce <= _nonce) revert SIK_NonceTooSmall();
        uint256 old = _nonce;
        _nonce = newNonce;
        emit SIK_Reseeded(old, newNonce, msg.sender);
    }

    /// @notice Emits a deterministic digest of the current configuration (for off-chain monitoring).
    function imprintDomain() external whenLive nonReentrant {
        bytes32 d = keccak256(
            abi.encode(
                SIK_DOMAIN,
                _delay,
                _minDelay,
                _maxDelay,
                _maxIndex,
                _index,
                _nonce,
                _paused,
                block.chainid
            )
        );
        emit SIK_DomainImprint(d, msg.sender);
    }

    /// @notice Pilot proposes `nextIndex`; helmsman can activate after delay with the correct `salt`.
    function proposeIndex(uint64 nextIndex, bytes32 salt) external onlyPilot whenLive nonReentrant returns (bytes32 proposalId) {
        if (_pendingExecuteAfter != 0) revert SIK_ProposalExists();
        if (nextIndex == 0 || nextIndex > _maxIndex) revert SIK_InvalidIndex();
        if (block.timestamp < _lastQueueAt + SIK_MIN_SPACING_SECONDS) revert SIK_TooEarly();

        proposalId = _proposalId(nextIndex, salt, _nonce);
        _pendingId = proposalId;
        _pendingIndex = nextIndex;
        _pendingExecuteAfter = block.timestamp + _delay;
        _lastQueueAt = block.timestamp;

        ProposalMeta storage m = _proposal[proposalId];
        m.nextIndex = nextIndex;
        m.previousIndex = _index;
        m.nonce = _nonce;
