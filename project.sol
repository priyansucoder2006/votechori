// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/// @title Votebank - A simple, secure voting smart contract
/// @author ChatGPT
/// @notice This contract provides a straightforward voting system with voter registration,
/// candidate management, delegation, and a controllable voting period.
/// @dev No external imports used so it can be compiled as a single file.

contract Votebank {
    // -----------------------------
    // Structures
    // -----------------------------
    struct Candidate {
        uint id;
        string name;
        uint voteCount;
        bool exists;
    }

    struct Voter {
        bool registered;
        bool voted;
        address delegate;
        uint weight; // weight is 1 by default for registered voters
        uint votedFor; // candidate id
    }

    // -----------------------------
    // State variables
    // -----------------------------
    address public owner;
    string public electionName;

    // voting window
    uint public startTime; // unix timestamp
    uint public endTime;   // unix timestamp

    // candidates
    uint private nextCandidateId;
    mapping(uint => Candidate) private candidates;
    uint[] private candidateIds;

    // voters
    mapping(address => Voter) private voters;
    uint public totalRegisteredVoters;

    bool public paused;

    // -----------------------------
    // Events
    // -----------------------------
    event CandidateAdded(uint indexed id, string name);
    event VoterRegistered(address indexed voter);
    event Voted(address indexed voter, uint indexed candidateId, uint weight);
    event Delegated(address indexed from, address indexed to);
    event VotingStarted(uint startTime, uint endTime);
    event VotingStopped();
    event Paused(address indexed by);
    event Unpaused(address indexed by);

    // -----------------------------
    // Modifiers
    // -----------------------------
    modifier onlyOwner() {
        require(msg.sender == owner, "only owner");
        _;
    }

    modifier duringVoting() {
        require(!paused, "contract paused");
        require(startTime != 0 && block.timestamp >= startTime, "voting not started");
        require(block.timestamp <= endTime, "voting ended");
        _;
    }

    modifier onlyWhenNotPaused() {
        require(!paused, "contract paused");
        _;
    }

    // -----------------------------
    // Constructor
    // -----------------------------
    constructor(string memory _electionName) {
        owner = msg.sender;
        electionName = _electionName;
        nextCandidateId = 1; // start candidate IDs at 1
    }

    // -----------------------------
    // Owner / Admin functions
    // -----------------------------

    /// @notice Add a candidate before voting starts
    function addCandidate(string calldata _name) external onlyOwner onlyWhenNotPaused {
        require(bytes(_name).length > 0, "name required");
        require(startTime == 0 || block.timestamp < startTime, "cannot add after start");

        uint id = nextCandidateId++;
        candidates[id] = Candidate({
            id: id,
            name: _name,
            voteCount: 0,
            exists: true
        });
        candidateIds.push(id);
        emit CandidateAdded(id, _name);
    }

    /// @notice Register a voter. Owner can register many addresses.
    function registerVoter(address _voter) public onlyOwner onlyWhenNotPaused {
        require(_voter != address(0), "zero address");
        Voter storage v = voters[_voter];
        require(!v.registered, "already registered");
        v.registered = true;
        v.weight = 1;
        totalRegisteredVoters += 1;
        emit VoterRegistered(_voter);
    }

    /// @notice Batch register voters (gas saving appropriation to caller)
    function registerVoters(address[] calldata _voters) external onlyOwner onlyWhenNotPaused {
        for (uint i = 0; i < _voters.length; i++) {
            registerVoter(_voters[i]);
        }
    }

    /// @notice Set the voting window. Can only be done by owner and before voting starts.
    function setVotingPeriod(uint _start, uint _end) external onlyOwner onlyWhenNotPaused {
        require(_start > block.timestamp, "start must be future");
        require(_end > _start, "end must be after start");
        require(startTime == 0 || block.timestamp < startTime, "voting already configured or started");

        startTime = _start;
        endTime = _end;
        emit VotingStarted(_start, _end);
    }

    /// @notice Stop voting immediately (owner only) -- does not delete state
    function stopVoting() external onlyOwner {
        endTime = block.timestamp;
        emit VotingStopped();
    }

    /// @notice Pause contract for emergency
    function pause() external onlyOwner {
        paused = true;
        emit Paused(msg.sender);
    }

    /// @notice Unpause contract
    function unpause() external onlyOwner {
        paused = false;
        emit Unpaused(msg.sender);
    }

    // -----------------------------
    // Voter functions
    // -----------------------------

    /// @notice Delegate your vote to another registered voter
    function delegate(address _to) external duringVoting {
        Voter storage sender = voters[msg.sender];
        require(sender.registered, "not registered");
        require(!sender.voted, "already voted");
        require(_to != msg.sender, "cannot delegate to self");

        // follow the chain of delegation to prevent loops
        address curr = _to;
        while (voters[curr].delegate != address(0)) {
            curr = voters[curr].delegate;
            require(curr != msg.sender, "delegation loop");
        }

        sender.voted = true;
        sender.delegate = _to;
        emit Delegated(msg.sender, _to);

        Voter storage recipient = voters[curr];
        // if the recipient has already voted, add weight to that candidate directly
        if (recipient.voted) {
            require(recipient.votedFor != 0, "recipient votedFor missing");
            candidates[recipient.votedFor].voteCount += sender.weight;
            emit Voted(msg.sender, recipient.votedFor, sender.weight);
        } else {
            // otherwise add weight to recipient
            recipient.weight += sender.weight;
        }
    }

    /// @notice Cast a vote for candidate id
    function vote(uint _candidateId) external duringVoting {
        Voter storage sender = voters[msg.sender];
        require(sender.registered, "not registered");
        require(!sender.voted, "already voted");
        require(sender.weight > 0, "no voting weight");
        require(candidates[_candidateId].exists, "invalid candidate");

        sender.voted = true;
        sender.votedFor = _candidateId;

        candidates[_candidateId].voteCount += sender.weight;

        emit Voted(msg.sender, _candidateId, sender.weight);
    }

    // -----------------------------
    // Views / Utilities
    // -----------------------------

    /// @notice Get candidate details
    function getCandidate(uint _id) external view returns (uint id, string memory name, uint voteCount) {
        Candidate storage c = candidates[_id];
        require(c.exists, "no candidate");
        return (c.id, c.name, c.voteCount);
    }

    /// @notice Get list of all candidate ids
    function getAllCandidateIds() external view returns (uint[] memory) {
        return candidateIds;
    }

    /// @notice Check voter details
    function getVoter(address _addr) external view returns (bool registered, bool voted, address delegateAddr, uint weight, uint votedFor) {
        Voter storage v = voters[_addr];
        return (v.registered, v.voted, v.delegate, v.weight, v.votedFor);
    }

    /// @notice Returns the winning candidate id(s). If tie, returns all tied IDs.
    function winners() external view returns (uint[] memory) {
        // find max votes
        uint maxVotes = 0;
        for (uint i = 0; i < candidateIds.length; i++) {
            uint id = candidateIds[i];
            uint vc = candidates[id].voteCount;
            if (vc > maxVotes) maxVotes = vc;
        }

        // count how many winners
        uint count = 0;
        for (uint i = 0; i < candidateIds.length; i++) {
            if (candidates[candidateIds[i]].voteCount == maxVotes) count++;
        }

        uint[] memory result = new uint[](count);
        uint idx = 0;
        for (uint i = 0; i < candidateIds.length; i++) {
            if (candidates[candidateIds[i]].voteCount == maxVotes) {
                result[idx++] = candidateIds[i];
            }
        }
        return result;
    }

    /// @notice Total votes cast across all candidates
    function totalVotesCast() external view returns (uint) {
        uint total = 0;
        for (uint i = 0; i < candidateIds.length; i++) {
            total += candidates[candidateIds[i]].voteCount;
        }
        return total;
    }

    // -----------------------------
    // Safety / housekeeping
    // -----------------------------

    /// @notice Transfer ownership to another address
    function transferOwnership(address _newOwner) external onlyOwner {
        require(_newOwner != address(0), "zero address");
        owner = _newOwner;
    }

    /// @notice Clear candidate list and data (careful!). Only owner and only when paused.
    /// @dev This is destructive: it removes all candidate records and resets ids. Use with caution.
    function clearCandidates() external onlyOwner {
        require(paused, "must be paused to clear");
        for (uint i = 0; i < candidateIds.length; i++) {
            delete candidates[candidateIds[i]];
        }
        delete candidateIds;
        nextCandidateId = 1;
    }

    // -----------------------------
    // Notes
    // -----------------------------
    // - This contract intentionally keeps voter weights as integers and simple delegation.
    // - For production, consider adding:
    //    * EIP-712 off-chain signed voting (gas savings)
    //    * Role-based access control instead of a single owner
    //    * More robust candidate metadata (ipfs hash, description)
    //    * Upgradability via proxy patterns
    //    * Tests that simulate delegation chains and edge-cases
}
