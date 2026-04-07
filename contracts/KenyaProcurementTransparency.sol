// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title KenyaProcurementTransparency
/// @author OpenAI
/// @notice A blockchain-based public procurement prototype for transparent tendering,
/// delivery verification, inspection, and conditional payment.
/// @dev This contract demonstrates sealed bidding, role-based access control,
/// state-driven workflow enforcement, and auditability for academic use.
contract KenyaProcurementTransparency {
    address public admin;
    address public pendingAdmin;
    address public inspector;

    uint256 public constant MAX_BIDDERS = 100;

    /// @notice Represents the lifecycle stages of the procurement process.
    enum TenderStatus {
        None,
        Created,
        RevealOpen,
        Evaluated,
        Awarded,
        Delivered,
        Rejected,
        Accepted,
        Paid
    }

    TenderStatus private _status;

    /// @notice Stores tender metadata.
    struct Tender {
        string tenderNumber;
        string title;
        string description;
        uint256 submissionDeadline;
        uint256 contractAmount;
        string qualificationNote;
        bool exists;
    }

    /// @notice Stores bidder commitment and revealed bid information.
    struct Bid {
        bytes32 sealedBidHash;
        bool submitted;
        bool revealed;
        uint256 amount;
        bool valid;
    }

    Tender private _tender;

    mapping(address => bool) public registeredBidders;
    mapping(address => string) public bidderDescriptions;
    mapping(address => Bid) public bids;
    address[] public bidderList;

    address private _winner;
    uint256 public lowestBid;
    uint256 private _submittedBidCount;
    bytes32 public deliveryEvidenceHash;
    bytes32 public inspectionReportHash;
    string public rejectionReason;
    bool public paymentReleased;

    // ------------------------------------------------------------------------
    // Custom Errors
    // ------------------------------------------------------------------------

    error OnlyAdmin();
    error OnlyInspector();
    error OnlyWinner();
    error NotRegisteredBidder();
    error TenderDoesNotExist();
    error SubmissionDeadlinePassed();
    error SubmissionDeadlineNotReached();
    error InvalidTenderStage();
    error InspectorNotAssigned();
    error ReentrancyDetected();
    error PaymentTransferFailed();

    error TenderAlreadyCreated();
    error ContractAmountMustBeGreaterThanZero();
    error DeadlineMustBeInFuture();
    error InvalidAddress();
    error InspectorStageLocked();
    error AlreadyCurrentAdmin();
    error NotPendingAdmin();
    error BidderAlreadyRegistered();
    error DescriptionRequired();
    error BidderLimitReached();
    error BidAlreadySubmitted();
    error InvalidSealedBidHash();
    error NoBidSubmitted();
    error BidAlreadyRevealed();
    error RevealMismatch();
    error NoValidRevealedBids();
    error NoWinnerSelected();
    error DocumentTypeRequired();
    error ReferenceNumberRequired();
    error InvalidDeliveryEvidenceHash();
    error InvalidInspectionReportHash();
    error ReasonRequired();
    error PaymentAlreadyReleased();
    error WinnerNotSet();
    error LowestBidNotSet();
    error InsufficientContractBalance();
    error InvalidYear();
    error InvalidMonth();
    error InvalidDay();
    error InvalidHour();
    error InvalidMinute();
    error InvalidUtcOffset();

    // ------------------------------------------------------------------------
    // Events
    // ------------------------------------------------------------------------

    event TenderCreated(
        string tenderNumber,
        string title,
        uint256 submissionDeadline,
        uint256 contractAmount
    );

    event BidderRegistered(address bidder, string description);
    event BidSubmitted(address bidder);
    event RevealPhaseOpened();
    event BidRevealed(address bidder, uint256 amount);
    event TenderEvaluated(address winner, uint256 lowestBid);
    event TenderAwarded(address winner, uint256 amount);
    event DeliverySubmitted(address winner, bytes32 deliveryEvidenceHash);
    event DeliveryAccepted(address inspector, bytes32 inspectionReportHash);
    event DeliveryRejected(address inspector, string reason);
    event PaymentReleased(address winner, uint256 amount);
    event ContractFunded(address indexed funder, uint256 amount, uint256 newBalance);

    event InspectorAssigned(address inspector);
    event AdminTransferInitiated(address indexed currentAdmin, address indexed newAdmin);
    event AdminTransferred(address indexed oldAdmin, address indexed newAdmin);

    // ------------------------------------------------------------------------
    // Modifiers
    // ------------------------------------------------------------------------

    /// @notice Restricts function access to the current admin.
    modifier onlyAdmin() {
        if (msg.sender != admin) revert OnlyAdmin();
        _;
    }

    /// @notice Restricts function access to the assigned inspector.
    modifier onlyInspector() {
        if (inspector == address(0)) revert InspectorNotAssigned();
        if (msg.sender != inspector) revert OnlyInspector();
        _;
    }

    /// @notice Restricts function access to the current winning bidder.
    modifier onlyWinner() {
        if (msg.sender != _winner) revert OnlyWinner();
        _;
    }

    /// @notice Restricts bidding actions to registered bidders only.
    modifier onlyRegisteredBidder() {
        if (!registeredBidders[msg.sender]) revert NotRegisteredBidder();
        _;
    }

    /// @notice Ensures a tender has already been created.
    modifier tenderExists() {
        if (!_tender.exists) revert TenderDoesNotExist();
        _;
    }

    /// @notice Ensures the action is performed before the bid submission deadline.
    modifier beforeDeadline() {
        if (block.timestamp >= _tender.submissionDeadline) revert SubmissionDeadlinePassed();
        _;
    }

    /// @notice Ensures the action is performed after the bid submission deadline.
    modifier afterDeadline() {
        if (block.timestamp < _tender.submissionDeadline) revert SubmissionDeadlineNotReached();
        _;
    }

    /// @notice Ensures the function is called only at the required lifecycle stage.
    /// @param _expectedStatus The expected tender status.
    modifier inStatus(TenderStatus _expectedStatus) {
        if (_status != _expectedStatus) revert InvalidTenderStage();
        _;
    }

    /// @notice Prevents reentrant calls to sensitive functions.
    modifier nonReentrant() {
        if (_locked) revert ReentrancyDetected();
        _locked = true;
        _;
        _locked = false;
    }

    // ------------------------------------------------------------------------
    // Reentrancy State
    // ------------------------------------------------------------------------

    bool private _locked;

    // ------------------------------------------------------------------------
    // Constructor
    // ------------------------------------------------------------------------

    /// @notice Sets the deployer as the initial admin.
    constructor() payable {
        admin = msg.sender;
    }

    // ------------------------------------------------------------------------
    // Admin and Role Management
    // ------------------------------------------------------------------------

    /// @notice Creates the tender using local date, time, and UTC offset.
    /// @dev Improves usability by converting human-readable local time into Unix time internally.
    /// @param _tenderNumber Official tender reference number.
    /// @param _title Tender title.
    /// @param _description Tender description.
    /// @param _submissionDeadlineYear Submission deadline year.
    /// @param _submissionDeadlineMonth Submission deadline month (1-12).
    /// @param _submissionDeadlineDay Submission deadline day.
    /// @param _submissionDeadlineHour Submission deadline hour in 24-hour format.
    /// @param _submissionDeadlineMinute Submission deadline minute.
    /// @param _utcOffsetHours UTC offset in hours (e.g. 3 for EAT).
    /// @param _contractAmount Payment amount to be released after acceptance.
    /// @param _qualificationNote Eligibility or qualification requirement.
    function createTenderWithLocalTime(
        string memory _tenderNumber,
        string memory _title,
        string memory _description,
        uint256 _submissionDeadlineYear,
        uint256 _submissionDeadlineMonth,
        uint256 _submissionDeadlineDay,
        uint256 _submissionDeadlineHour,
        uint256 _submissionDeadlineMinute,
        int256 _utcOffsetHours,
        uint256 _contractAmount,
        string memory _qualificationNote
    ) external onlyAdmin {
        if (_tender.exists) revert TenderAlreadyCreated();
        if (_contractAmount == 0) revert ContractAmountMustBeGreaterThanZero();

        uint256 submissionDeadline = _toTimestampWithOffset(
            _submissionDeadlineYear,
            _submissionDeadlineMonth,
            _submissionDeadlineDay,
            _submissionDeadlineHour,
            _submissionDeadlineMinute,
            _utcOffsetHours
        );

        if (submissionDeadline <= block.timestamp) revert DeadlineMustBeInFuture();

        _tender = Tender({
            tenderNumber: _tenderNumber,
            title: _title,
            description: _description,
            submissionDeadline: submissionDeadline,
            contractAmount: _contractAmount,
            qualificationNote: _qualificationNote,
            exists: true
        });

        _status = TenderStatus.Created;

        emit TenderCreated(_tenderNumber, _title, submissionDeadline, _contractAmount);
    }

    /// @notice Assigns or updates the inspector address.
    /// @dev Inspector can be changed only before final inspection/payment stages.
    /// @param _inspector Address of the inspection authority.
    function setInspector(address _inspector) external onlyAdmin tenderExists {
        if (_inspector == address(0)) revert InvalidAddress();
        if (
            _status == TenderStatus.Accepted ||
            _status == TenderStatus.Rejected ||
            _status == TenderStatus.Paid
        ) revert InspectorStageLocked();

        inspector = _inspector;
        emit InspectorAssigned(_inspector);
    }

    /// @notice Initiates transfer of admin authority to a new address.
    /// @param _newAdmin Address proposed as the next admin.
    function transferAdmin(address _newAdmin) external onlyAdmin {
        if (_newAdmin == address(0)) revert InvalidAddress();
        if (_newAdmin == admin) revert AlreadyCurrentAdmin();
        pendingAdmin = _newAdmin;

        emit AdminTransferInitiated(admin, _newAdmin);
    }

    /// @notice Accepts the pending admin role.
    /// @dev Must be called by the pending admin address.
    function acceptAdminRole() external {
        if (msg.sender != pendingAdmin) revert NotPendingAdmin();

        address oldAdmin = admin;
        admin = pendingAdmin;
        pendingAdmin = address(0);

        emit AdminTransferred(oldAdmin, admin);
    }

    /// @notice Registers a bidder address on the on-chain whitelist.
    /// @param _bidder Address of the supplier allowed to participate.
    /// @param _description Supplier description or company name.
    function registerBidder(address _bidder, string memory _description)
        external
        onlyAdmin
        tenderExists
        inStatus(TenderStatus.Created)
    {
        if (_bidder == address(0)) revert InvalidAddress();
        if (registeredBidders[_bidder]) revert BidderAlreadyRegistered();
        if (bytes(_description).length == 0) revert DescriptionRequired();
        if (bidderList.length >= MAX_BIDDERS) revert BidderLimitReached();

        registeredBidders[_bidder] = true;
        bidderDescriptions[_bidder] = _description;
        bidderList.push(_bidder);

        emit BidderRegistered(_bidder, _description);
    }

    // ------------------------------------------------------------------------
    // Bidding
    // ------------------------------------------------------------------------

    /// @notice Returns the hash used for creating a sealed bid commitment.
    /// @dev This helper is restricted to registered bidders for clearer procurement workflow control.
    /// @param _amount Bid amount.
    /// @param _secret Secret phrase used for bid commitment.
    /// @return The keccak256 packed hash of amount and secret.
    function getSealedBidHash(uint256 _amount, string memory _secret)
        external
        view
        onlyRegisteredBidder
        returns (bytes32)
    {
        return keccak256(abi.encodePacked(_amount, _secret));
    }

    /// @notice Allows a registered bidder to submit a sealed bid hash.
    /// @dev Bid must be submitted before the deadline and only once.
    /// @param _sealedBidHash keccak256 hash of bid amount and secret.
    function submitSealedBid(bytes32 _sealedBidHash)
        external
        tenderExists
        onlyRegisteredBidder
        beforeDeadline
        inStatus(TenderStatus.Created)
    {
        if (bids[msg.sender].submitted) revert BidAlreadySubmitted();
        if (_sealedBidHash == bytes32(0)) revert InvalidSealedBidHash();

        bids[msg.sender] = Bid({
            sealedBidHash: _sealedBidHash,
            submitted: true,
            revealed: false,
            amount: 0,
            valid: false
        });

        unchecked {
            ++_submittedBidCount;
        }

        emit BidSubmitted(msg.sender);
    }

    /// @notice Opens the reveal phase after the submission deadline.
    function openRevealPhase()
        external
        onlyAdmin
        tenderExists
        afterDeadline
        inStatus(TenderStatus.Created)
    {
        _status = TenderStatus.RevealOpen;
        emit RevealPhaseOpened();
    }

    /// @notice Reveals a previously committed bid.
    /// @param _amount Bid amount.
    /// @param _secret Secret string originally used to generate the sealed hash.
    function revealBid(uint256 _amount, string memory _secret)
        external
        tenderExists
        onlyRegisteredBidder
        inStatus(TenderStatus.RevealOpen)
    {
        Bid storage bidderBid = bids[msg.sender];

        if (!bidderBid.submitted) revert NoBidSubmitted();
        if (bidderBid.revealed) revert BidAlreadyRevealed();

        bytes32 computedHash = keccak256(abi.encodePacked(_amount, _secret));
        if (computedHash != bidderBid.sealedBidHash) revert RevealMismatch();

        bidderBid.revealed = true;
        bidderBid.amount = _amount;
        bidderBid.valid = true;

        emit BidRevealed(msg.sender, _amount);
    }

    // ------------------------------------------------------------------------
    // Evaluation and Award
    // ------------------------------------------------------------------------

    /// @notice Evaluates all valid revealed bids and selects the lowest bid.
    /// @dev Simplified prototype logic: lowest responsive revealed bid wins.
    function evaluateTender()
        external
        onlyAdmin
        tenderExists
        inStatus(TenderStatus.RevealOpen)
    {
        address bestBidder = address(0);
        uint256 bestAmount = type(uint256).max;
        uint256 bidderCount = bidderList.length;

        for (uint256 i = 0; i < bidderCount; ) {
            address bidder = bidderList[i];
            Bid memory currentBid = bids[bidder];

            if (currentBid.valid && currentBid.revealed && currentBid.amount < bestAmount) {
                bestAmount = currentBid.amount;
                bestBidder = bidder;
            }

            unchecked {
                ++i;
            }
        }

        if (bestBidder == address(0)) revert NoValidRevealedBids();

        _winner = bestBidder;
        lowestBid = bestAmount;
        _status = TenderStatus.Evaluated;

        emit TenderEvaluated(bestBidder, bestAmount);
    }

    /// @notice Finalizes the winning bidder after evaluation.
    function awardTender()
        external
        onlyAdmin
        tenderExists
        inStatus(TenderStatus.Evaluated)
    {
        if (_winner == address(0)) revert NoWinnerSelected();

        _status = TenderStatus.Awarded;

        emit TenderAwarded(_winner, lowestBid);
    }

    // ------------------------------------------------------------------------
    // Delivery and Inspection
    // ------------------------------------------------------------------------

    /// @notice Generates a structured hash for delivery evidence using readable local date and time.
    /// @dev This helper improves usability by allowing only the current winner to hash delivery evidence references consistently.
    /// @param _documentType Type of evidence document (e.g. DeliveryNote, Invoice, GRN).
    /// @param _referenceNumber Reference number of the evidence document.
    /// @param _evidenceYear Evidence date year.
    /// @param _evidenceMonth Evidence date month (1-12).
    /// @param _evidenceDay Evidence date day.
    /// @param _evidenceHour Evidence date hour in 24-hour format.
    /// @param _evidenceMinute Evidence date minute.
    /// @param _utcOffsetHours UTC offset in hours (e.g. 3 for EAT).
    /// @return evidenceTimestamp Unix timestamp computed from the provided local date and time.
    /// @return deliveryEvidenceComputedHash keccak256 hash of document type, reference number, and timestamp.
    function getDeliveryEvidenceHashWithLocalTime(
        string memory _documentType,
        string memory _referenceNumber,
        uint256 _evidenceYear,
        uint256 _evidenceMonth,
        uint256 _evidenceDay,
        uint256 _evidenceHour,
        uint256 _evidenceMinute,
        int256 _utcOffsetHours
    )
        external
        view
        onlyWinner
        returns (
            uint256 evidenceTimestamp,
            bytes32 deliveryEvidenceComputedHash
        )
    {
        if (bytes(_documentType).length == 0) revert DocumentTypeRequired();
        if (bytes(_referenceNumber).length == 0) revert ReferenceNumberRequired();

        evidenceTimestamp = _toTimestampWithOffset(
            _evidenceYear,
            _evidenceMonth,
            _evidenceDay,
            _evidenceHour,
            _evidenceMinute,
            _utcOffsetHours
        );

        deliveryEvidenceComputedHash = keccak256(
            abi.encodePacked(_documentType, _referenceNumber, evidenceTimestamp)
        );
    }

    /// @notice Generates a structured hash for inspection reports using readable local date and time.
    /// @dev This helper improves usability by allowing only the assigned inspector to hash inspection references consistently.
    /// @param _documentType Type of inspection document (e.g. InspectionReport, AcceptanceCertificate, VerificationNote).
    /// @param _referenceNumber Reference number of the inspection document.
    /// @param _reportYear Inspection report date year.
    /// @param _reportMonth Inspection report date month (1-12).
    /// @param _reportDay Inspection report date day.
    /// @param _reportHour Inspection report date hour in 24-hour format.
    /// @param _reportMinute Inspection report date minute.
    /// @param _utcOffsetHours UTC offset in hours (e.g. 3 for EAT).
    /// @return reportTimestamp Unix timestamp computed from the provided local date and time.
    /// @return inspectionReportComputedHash keccak256 hash of document type, reference number, and timestamp.
    function getInspectionReportHashWithLocalTime(
        string memory _documentType,
        string memory _referenceNumber,
        uint256 _reportYear,
        uint256 _reportMonth,
        uint256 _reportDay,
        uint256 _reportHour,
        uint256 _reportMinute,
        int256 _utcOffsetHours
    )
        external
        view
        onlyInspector
        returns (
            uint256 reportTimestamp,
            bytes32 inspectionReportComputedHash
        )
    {
        if (bytes(_documentType).length == 0) revert DocumentTypeRequired();
        if (bytes(_referenceNumber).length == 0) revert ReferenceNumberRequired();

        reportTimestamp = _toTimestampWithOffset(
            _reportYear,
            _reportMonth,
            _reportDay,
            _reportHour,
            _reportMinute,
            _utcOffsetHours
        );

        inspectionReportComputedHash = keccak256(
            abi.encodePacked(_documentType, _referenceNumber, reportTimestamp)
        );
    }

    /// @notice Allows only the winner to submit delivery evidence.
    /// @param _deliveryEvidenceHash Hash of the delivery note, invoice, or delivery proof.
    function submitDeliveryEvidence(bytes32 _deliveryEvidenceHash)
        external
        tenderExists
        inStatus(TenderStatus.Awarded)
        onlyWinner
    {
        if (inspector == address(0)) revert InspectorNotAssigned();
        if (_deliveryEvidenceHash == bytes32(0)) revert InvalidDeliveryEvidenceHash();

        deliveryEvidenceHash = _deliveryEvidenceHash;
        _status = TenderStatus.Delivered;

        emit DeliverySubmitted(msg.sender, _deliveryEvidenceHash);
    }

    /// @notice Accepts delivery after successful inspection.
    /// @param _inspectionReportHash Hash of the inspection or acceptance report.
    function acceptDelivery(bytes32 _inspectionReportHash)
        external
        onlyInspector
        tenderExists
        inStatus(TenderStatus.Delivered)
    {
        if (_inspectionReportHash == bytes32(0)) revert InvalidInspectionReportHash();

        inspectionReportHash = _inspectionReportHash;
        _status = TenderStatus.Accepted;

        emit DeliveryAccepted(msg.sender, _inspectionReportHash);
    }

    /// @notice Rejects delivery and records the reason.
    /// @param _reason Textual reason for rejection.
    function rejectDelivery(string memory _reason)
        external
        onlyInspector
        tenderExists
        inStatus(TenderStatus.Delivered)
    {
        if (bytes(_reason).length == 0) revert ReasonRequired();

        rejectionReason = _reason;
        _status = TenderStatus.Rejected;

        emit DeliveryRejected(msg.sender, _reason);
    }

    // ------------------------------------------------------------------------
    // Funding and Payment
    // ------------------------------------------------------------------------

    /// @notice Allows the admin to fund the contract with ETH for later payment.
    function fundContract() external payable onlyAdmin {
        emit ContractFunded(msg.sender, msg.value, address(this).balance);
    }

    /// @notice Releases payment to the winning bidder after inspection acceptance.
    function releasePayment()
        external
        onlyAdmin
        tenderExists
        inStatus(TenderStatus.Accepted)
        nonReentrant
    {
        if (paymentReleased) revert PaymentAlreadyReleased();
        if (_winner == address(0)) revert WinnerNotSet();
        if (lowestBid == 0) revert LowestBidNotSet();
        if (address(this).balance < lowestBid) revert InsufficientContractBalance();

        paymentReleased = true;
        _status = TenderStatus.Paid;

        (bool success, ) = payable(_winner).call{value: lowestBid}("");
        if (!success) revert PaymentTransferFailed();

        emit PaymentReleased(_winner, lowestBid);
    }

    // ------------------------------------------------------------------------
    // View Functions
    // ------------------------------------------------------------------------

    /// @notice Returns the ETH balance currently held by the contract.
    /// @return The contract balance in wei.
    function getContractBalance() external view returns (uint256) {
        return address(this).balance;
    }

    /// @notice Returns the number of registered bidders.
    /// @return Total bidder count.
    function getBidderCount() external view returns (uint256) {
        return bidderList.length;
    }

    /// @notice Returns the number of bids that have actually been submitted.
    /// @return Total submitted sealed bids.
    function getSubmittedBidCount() external view returns (uint256) {
        return _submittedBidCount;
    }

    /// @notice Returns all registered bidders with their indexes, addresses, and descriptions.
    /// @return indexes Sequential indexes of bidders in bidderList.
    /// @return bidderAddresses Registered bidder wallet addresses.
    /// @return descriptions Registered bidder descriptions or company names.
    function getAllRegisteredBidders()
        external
        view
        returns (
            uint256[] memory indexes,
            address[] memory bidderAddresses,
            string[] memory descriptions
        )
    {
        uint256 count = bidderList.length;

        indexes = new uint256[](count);
        bidderAddresses = new address[](count);
        descriptions = new string[](count);

        for (uint256 i = 0; i < count; ) {
            address bidder = bidderList[i];
            indexes[i] = i;
            bidderAddresses[i] = bidder;
            descriptions[i] = bidderDescriptions[bidder];

            unchecked {
                ++i;
            }
        }

        return (indexes, bidderAddresses, descriptions);
    }

    /// @notice Returns all bidder records including profile and bid state in a single read.
    /// @dev Frontends can display the sealed hash before reveal, and display amount after reveal/opening.
    /// @return indexes Sequential indexes of bidders in bidderList.
    /// @return bidderAddresses Registered bidder wallet addresses.
    /// @return descriptions Registered bidder descriptions or company names.
    /// @return submitted Whether each bidder submitted a sealed bid.
    /// @return revealed Whether each bidder revealed the bid.
    /// @return amounts Revealed bid amounts.
    /// @return valid Whether each bid is considered valid.
    /// @return sealedBidHashes Submitted sealed bid hashes.
    function getAllBidDetails()
        external
        view
        returns (
            uint256[] memory indexes,
            address[] memory bidderAddresses,
            string[] memory descriptions,
            bool[] memory submitted,
            bool[] memory revealed,
            uint256[] memory amounts,
            bool[] memory valid,
            bytes32[] memory sealedBidHashes
        )
    {
        uint256 count = bidderList.length;

        indexes = new uint256[](count);
        bidderAddresses = new address[](count);
        descriptions = new string[](count);
        submitted = new bool[](count);
        revealed = new bool[](count);
        amounts = new uint256[](count);
        valid = new bool[](count);
        sealedBidHashes = new bytes32[](count);

        for (uint256 i = 0; i < count; ) {
            address bidder = bidderList[i];
            Bid memory currentBid = bids[bidder];

            indexes[i] = i;
            bidderAddresses[i] = bidder;
            descriptions[i] = bidderDescriptions[bidder];
            submitted[i] = currentBid.submitted;
            revealed[i] = currentBid.revealed;
            amounts[i] = currentBid.amount;
            valid[i] = currentBid.valid;
            sealedBidHashes[i] = currentBid.sealedBidHash;

            unchecked {
                ++i;
            }
        }

        return (
            indexes,
            bidderAddresses,
            descriptions,
            submitted,
            revealed,
            amounts,
            valid,
            sealedBidHashes
        );
    }

    /// @notice Returns registered bidder details for a specific address.
    /// @param _bidder Address of the bidder.
    /// @return isRegistered Whether the address is registered.
    /// @return description Supplier description or company name.
    function getBidderProfile(address _bidder)
        external
        view
        returns (bool isRegistered, string memory description)
    {
        return (registeredBidders[_bidder], bidderDescriptions[_bidder]);
    }

    /// @notice Returns bid details for a given bidder address.
    /// @param _bidder Address of the bidder.
    /// @return submitted Whether a bid was submitted.
    /// @return revealed Whether the bid was revealed.
    /// @return amount The revealed amount.
    /// @return valid Whether the bid is considered valid.
    /// @return sealedBidHash The sealed bid hash originally submitted.
    function getBidDetails(address _bidder)
        external
        view
        returns (
            bool submitted,
            bool revealed,
            uint256 amount,
            bool valid,
            bytes32 sealedBidHash
        )
    {
        Bid memory b = bids[_bidder];
        return (b.submitted, b.revealed, b.amount, b.valid, b.sealedBidHash);
    }

    /// @notice Returns the current winning bidder address and description.
    /// @return winnerAddress Address of the current winning bidder.
    /// @return winnerDescription Description or company name of the current winning bidder.
    function winner()
        external
        view
        returns (
            address winnerAddress,
            string memory winnerDescription
        )
    {
        return (_winner, bidderDescriptions[_winner]);
    }

    /// @notice Returns the lowest bid details including bidder identity.
    /// @return lowestBidAmount The lowest revealed valid bid amount.
    /// @return lowestBidder Address of the lowest bidder.
    /// @return lowestBidderDescription Description or company name of the lowest bidder.
    function getLowestBidDetails()
        external
        view
        returns (
            uint256 lowestBidAmount,
            address lowestBidder,
            string memory lowestBidderDescription
        )
    {
        return (lowestBid, _winner, bidderDescriptions[_winner]);
    }

    /// @notice Returns the current tender status as both enum value and readable text.
    /// @return currentStatus Current lifecycle stage as enum value.
    /// @return currentStatusText Human-readable name of the current tender stage.
    function status()
        external
        view
        returns (
            TenderStatus currentStatus,
            string memory currentStatusText
        )
    {
        if (!_tender.exists) {
            return (TenderStatus.None, "NoTenderCreated");
        }

        return (_status, _getStatusText(_status));
    }

    /// @notice Returns the current tender status as text.
    /// @return statusText Human-readable name of the current tender stage.
    function getCurrentStatusText() external view returns (string memory statusText) {
        if (!_tender.exists) {
            return "NoTenderCreated";
        }

        return _getStatusText(_status);
    }

    /// @notice Returns tender details with both raw and human-readable submission deadline fields.
    /// @return tenderNumber Tender reference number.
    /// @return title Tender title.
    /// @return description Tender description.
    /// @return submissionDeadlineTimestamp Raw Unix timestamp for the submission deadline.
    /// @return submissionDeadlineYear Submission deadline year.
    /// @return submissionDeadlineMonth Submission deadline month.
    /// @return submissionDeadlineDay Submission deadline day.
    /// @return submissionDeadlineHour Submission deadline hour in 24-hour format.
    /// @return submissionDeadlineMinute Submission deadline minute.
    /// @return contractAmount Payment amount for the contract.
    /// @return qualificationNote Supplier qualification requirement.
    /// @return exists Whether the tender exists.
    function tender()
        external
        view
        returns (
            string memory tenderNumber,
            string memory title,
            string memory description,
            uint256 submissionDeadlineTimestamp,
            uint256 submissionDeadlineYear,
            uint256 submissionDeadlineMonth,
            uint256 submissionDeadlineDay,
            uint256 submissionDeadlineHour,
            uint256 submissionDeadlineMinute,
            uint256 contractAmount,
            string memory qualificationNote,
            bool exists
        )
    {
        (
            submissionDeadlineYear,
            submissionDeadlineMonth,
            submissionDeadlineDay,
            submissionDeadlineHour,
            submissionDeadlineMinute
        ) = _timestampToDateTime(_tender.submissionDeadline);

        return (
            _tender.tenderNumber,
            _tender.title,
            _tender.description,
            _tender.submissionDeadline,
            submissionDeadlineYear,
            submissionDeadlineMonth,
            submissionDeadlineDay,
            submissionDeadlineHour,
            submissionDeadlineMinute,
            _tender.contractAmount,
            _tender.qualificationNote,
            _tender.exists
        );
    }

    /// @notice Returns the submission deadline in human-readable UTC form.
    /// @return submissionDeadlineTimestamp Raw Unix timestamp for the submission deadline.
    /// @return submissionDeadlineYear Submission deadline year.
    /// @return submissionDeadlineMonth Submission deadline month.
    /// @return submissionDeadlineDay Submission deadline day.
    /// @return submissionDeadlineHour Submission deadline hour in 24-hour format.
    /// @return submissionDeadlineMinute Submission deadline minute.
    function getSubmissionDeadlineReadable()
        external
        view
        tenderExists
        returns (
            uint256 submissionDeadlineTimestamp,
            uint256 submissionDeadlineYear,
            uint256 submissionDeadlineMonth,
            uint256 submissionDeadlineDay,
            uint256 submissionDeadlineHour,
            uint256 submissionDeadlineMinute
        )
    {
        (
            submissionDeadlineYear,
            submissionDeadlineMonth,
            submissionDeadlineDay,
            submissionDeadlineHour,
            submissionDeadlineMinute
        ) = _timestampToDateTime(_tender.submissionDeadline);

        return (
            _tender.submissionDeadline,
            submissionDeadlineYear,
            submissionDeadlineMonth,
            submissionDeadlineDay,
            submissionDeadlineHour,
            submissionDeadlineMinute
        );
    }

    /// @notice Returns a summary of the current tender and award state.
    /// @return tenderNumber Tender reference number.
    /// @return title Tender title.
    /// @return description Tender description.
    /// @return submissionDeadlineTimestamp Raw Unix timestamp for the submission deadline.
    /// @return contractAmount Payment amount for the contract.
    /// @return qualificationNote Supplier qualification requirement.
    /// @return currentStatus Current lifecycle stage.
    /// @return currentStatusText Human-readable lifecycle stage.
    /// @return currentWinner Address of the current winner.
    /// @return currentWinnerDescription Description or company name of the current winner.
    /// @return winningBid Lowest revealed valid bid.
    function getTenderSummary()
        external
        view
        returns (
            string memory tenderNumber,
            string memory title,
            string memory description,
            uint256 submissionDeadlineTimestamp,
            uint256 contractAmount,
            string memory qualificationNote,
            TenderStatus currentStatus,
            string memory currentStatusText,
            address currentWinner,
            string memory currentWinnerDescription,
            uint256 winningBid
        )
    {
        return (
            _tender.tenderNumber,
            _tender.title,
            _tender.description,
            _tender.submissionDeadline,
            _tender.contractAmount,
            _tender.qualificationNote,
            _status,
            _getStatusText(_status),
            _winner,
            bidderDescriptions[_winner],
            lowestBid
        );
    }

    // ------------------------------------------------------------------------
    // Internal Time Conversion Helpers
    // ------------------------------------------------------------------------

    /// @notice Converts local date, time, and UTC offset into a Unix timestamp.
    /// @dev Uses fixed UTC offsets only; it does not support daylight-saving rules.
    /// @param year Calendar year.
    /// @param month Calendar month (1-12).
    /// @param day Calendar day.
    /// @param hour Hour in 24-hour format.
    /// @param minute Minute.
    /// @param utcOffsetHours UTC offset in hours (e.g. 3 for EAT).
    /// @return timestamp Unix timestamp in seconds.
    function _toTimestampWithOffset(
        uint256 year,
        uint256 month,
        uint256 day,
        uint256 hour,
        uint256 minute,
        int256 utcOffsetHours
    ) internal pure returns (uint256 timestamp) {
        if (year < 1970 || year > 2100) revert InvalidYear();
        if (month < 1 || month > 12) revert InvalidMonth();
        if (hour >= 24) revert InvalidHour();
        if (minute >= 60) revert InvalidMinute();
        if (utcOffsetHours < -12 || utcOffsetHours > 14) revert InvalidUtcOffset();

        uint256 daysInMonth = _getDaysInMonth(year, month);
        if (day < 1 || day > daysInMonth) revert InvalidDay();

        timestamp = _toTimestamp(year, month, day, hour, minute, 0);

        if (utcOffsetHours > 0) {
            timestamp -= uint256(utcOffsetHours) * 1 hours;
        } else if (utcOffsetHours < 0) {
            timestamp += uint256(-utcOffsetHours) * 1 hours;
        }
    }

    /// @notice Converts a Unix timestamp into calendar date and time.
    /// @param timestamp Unix timestamp in seconds.
    /// @return year Calendar year.
    /// @return month Calendar month.
    /// @return day Calendar day.
    /// @return hour Hour in 24-hour format.
    /// @return minute Minute.
    function _timestampToDateTime(uint256 timestamp)
        internal
        pure
        returns (
            uint256 year,
            uint256 month,
            uint256 day,
            uint256 hour,
            uint256 minute
        )
    {
        uint256 secondsAccountedFor = 0;
        uint256 secondsInYear;
        uint256 secondsInMonth;

        year = 1970;
        while (true) {
            secondsInYear = _isLeapYear(uint16(year)) ? 366 days : 365 days;
            if (secondsAccountedFor + secondsInYear > timestamp) {
                break;
            }
            secondsAccountedFor += secondsInYear;
            year++;
        }

        month = 1;
        while (true) {
            secondsInMonth = _getDaysInMonth(year, month) * 1 days;
            if (secondsAccountedFor + secondsInMonth > timestamp) {
                break;
            }
            secondsAccountedFor += secondsInMonth;
            month++;
        }

        day = ((timestamp - secondsAccountedFor) / 1 days) + 1;
        secondsAccountedFor += (day - 1) * 1 days;

        hour = (timestamp - secondsAccountedFor) / 1 hours;
        secondsAccountedFor += hour * 1 hours;

        minute = (timestamp - secondsAccountedFor) / 1 minutes;
    }

    /// @notice Converts a UTC date and time into a Unix timestamp.
    /// @param year Calendar year.
    /// @param month Calendar month.
    /// @param day Calendar day.
    /// @param hour Hour in 24-hour format.
    /// @param minute Minute.
    /// @param second Second.
    /// @return timestamp Unix timestamp in seconds.
    function _toTimestamp(
        uint256 year,
        uint256 month,
        uint256 day,
        uint256 hour,
        uint256 minute,
        uint256 second
    ) internal pure returns (uint256 timestamp) {
        uint16 i;

        for (i = 1970; i < year; ) {
            if (_isLeapYear(i)) {
                timestamp += 366 days;
            } else {
                timestamp += 365 days;
            }

            unchecked {
                ++i;
            }
        }

        uint8[12] memory monthDays = [
            uint8(31), 28, 31, 30, 31, 30,
            31, 31, 30, 31, 30, 31
        ];

        if (_isLeapYear(uint16(year))) {
            monthDays[1] = 29;
        }

        for (i = 1; i < month; ) {
            timestamp += uint256(monthDays[i - 1]) * 1 days;

            unchecked {
                ++i;
            }
        }

        timestamp += (day - 1) * 1 days;
        timestamp += hour * 1 hours;
        timestamp += minute * 1 minutes;
        timestamp += second;
    }

    /// @notice Converts a tender status enum value into readable text.
    /// @param _currentStatus Current lifecycle stage.
    /// @return statusText Human-readable name of the tender stage.
    function _getStatusText(TenderStatus _currentStatus)
        internal
        pure
        returns (string memory statusText)
    {
        if (_currentStatus == TenderStatus.None) return "NoTenderCreated";
        if (_currentStatus == TenderStatus.Created) return "Created";
        if (_currentStatus == TenderStatus.RevealOpen) return "RevealOpen";
        if (_currentStatus == TenderStatus.Evaluated) return "Evaluated";
        if (_currentStatus == TenderStatus.Awarded) return "Awarded";
        if (_currentStatus == TenderStatus.Delivered) return "Delivered";
        if (_currentStatus == TenderStatus.Rejected) return "Rejected";
        if (_currentStatus == TenderStatus.Accepted) return "Accepted";
        if (_currentStatus == TenderStatus.Paid) return "Paid";
        return "Unknown";
    }

    /// @notice Returns the number of days in a given month.
    /// @param year Calendar year.
    /// @param month Calendar month.
    /// @return Number of days in the month.
    function _getDaysInMonth(uint256 year, uint256 month) internal pure returns (uint256) {
        if (month == 2) {
            return _isLeapYear(uint16(year)) ? 29 : 28;
        } else if (
            month == 4 || month == 6 || month == 9 || month == 11
        ) {
            return 30;
        } else {
            return 31;
        }
    }

    /// @notice Determines whether a year is a leap year.
    /// @param year Calendar year.
    /// @return True if leap year, otherwise false.
    function _isLeapYear(uint16 year) internal pure returns (bool) {
        if (year % 4 != 0) return false;
        if (year % 100 != 0) return true;
        if (year % 400 != 0) return false;
        return true;
    }
}
