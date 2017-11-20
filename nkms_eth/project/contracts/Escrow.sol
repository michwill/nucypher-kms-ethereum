pragma solidity ^0.4.8;


import "./zeppelin/token/SafeERC20.sol";
import "./zeppelin/ownership/Ownable.sol";
import "./zeppelin/math/Math.sol";
import "./lib/LinkedList.sol";
import "./Miner.sol";
import "./HumanStandardToken.sol";


/**
* @notice Contract holds and locks client tokens.
Each client that lock his tokens will receive some compensation
**/
contract Escrow is Miner, Ownable {
    using LinkedList for LinkedList.Data;
    using SafeERC20 for HumanStandardToken;

    struct TokenInfo {
        uint256 value;
        uint256 lockedValue;
        uint256 releaseBlock;
        uint256 lastMintedBlock;
        uint256 decimals;
    }

    HumanStandardToken token;
    mapping (address => TokenInfo) public tokenInfo;
    LinkedList.Data tokenOwners;
    uint256 miningCoefficient;

    /**
    * @dev Throws if not locked tokens less then _value.
    * @param _owner Owner of tokens
    * @param _value Amount of tokens to check
    **/
    modifier whenNotLocked(address _owner, uint256 _value) {
        require(_value <= token.balanceOf(address(this)));
        require(_value <= tokenInfo[_owner].value - getLockedTokens(_owner));
        _;
    }

    /**
    * @notice The Escrow constructor sets address of token contract and coefficients for mining
    * @param _token Token contract
    * @param _rate Curve growing rate
    * @param _fractions Coefficient for fractions
    **/
    function Escrow(HumanStandardToken _token, uint256 _rate, uint256 _fractions)
        Miner(_token, _rate, _fractions)
    {
        token = _token;
    }

    /**
    * @notice Deposit tokens
    * @param _value Amount of token to deposit
    * @param _blocks Amount of blocks during which tokens will be locked
    **/
    function deposit(uint256 _value, uint256 _blocks) returns (bool success) {
        require(_value != 0);
        if (!tokenOwners.valueExists(msg.sender)) {
            tokenOwners.push(msg.sender, true);
        }
        tokenInfo[msg.sender].value = tokenInfo[msg.sender].value.add(_value);
        token.safeTransferFrom(msg.sender, address(this), _value);
        return lock(_value, _blocks);
    }

    /**
    * @notice Lock some tokens or increase lock
    * @param _value Amount of tokens which should lock
    * @param _blocks Amount of blocks during which tokens will be locked
    **/
    function lock(uint256 _value, uint256 _blocks) returns (bool success) {
        require(_value != 0 || _blocks != 0);
        uint256 lastLockedTokens = getLastLockedTokens();
        require(_value <= token.balanceOf(address(this)) &&
            _value <= tokenInfo[msg.sender].value.sub(lastLockedTokens));
        // Checks if tokens are not locked or lock can be increased
        require(
            lastLockedTokens == 0 &&
            !isEmptyReward(_value, _blocks) ||
            lastLockedTokens != 0 &&
            tokenInfo[msg.sender].releaseBlock >= block.number &&
            !isEmptyReward(_value + tokenInfo[msg.sender].lockedValue,
                _blocks + tokenInfo[msg.sender].releaseBlock - tokenInfo[msg.sender].lastMintedBlock)
        );
        if (lastLockedTokens == 0) {
            tokenInfo[msg.sender].lockedValue = _value;
            tokenInfo[msg.sender].releaseBlock = block.number.add(_blocks);
            tokenInfo[msg.sender].lastMintedBlock = block.number;
        } else {
            tokenInfo[msg.sender].lockedValue = tokenInfo[msg.sender].lockedValue.add(_value);
            tokenInfo[msg.sender].releaseBlock = tokenInfo[msg.sender].releaseBlock.add(_blocks);
        }
        return true;
    }

    /**
    * @notice Withdraw available amount of tokens back to owner
    * @param _value Amount of token to withdraw
    **/
    function withdraw(uint256 _value)
        whenNotLocked(msg.sender, _value)
        returns (bool success)
    {
        tokenInfo[msg.sender].value -= _value;
        token.safeTransfer(msg.sender, _value);
        return true;
    }

    /**
    * @notice Withdraw all amount of tokens back to owner (only if no locked)
    **/
    function withdrawAll()
//        whenNotLocked(msg.sender, tokenInfo[msg.sender].value)
        returns (bool success)
    {
        if (!tokenOwners.valueExists(msg.sender)) {
            return true;
        }
        uint256 value = tokenInfo[msg.sender].value;
        require(value <= token.balanceOf(address(this)));
        require(getLastLockedTokens() == 0);
        tokenOwners.remove(msg.sender);
        delete tokenInfo[msg.sender];
        token.safeTransfer(msg.sender, value);
        return true;
    }

    /**
    * @notice Terminate contract and refund to owners
    * @dev The called token contracts could try to re-enter this contract.
    Only supply token contracts you trust.
    **/
    function destroy() onlyOwner public {
        // Transfer tokens to owners
        var current = tokenOwners.step(0x0, true);
        while (current != 0x0) {
            token.safeTransfer(current, tokenInfo[current].value);
            current = tokenOwners.step(current, true);
        }
        token.safeTransfer(owner, token.balanceOf(address(this)));

        // Transfer Eth to owner and terminate contract
        selfdestruct(owner);
    }

    /**
    * @notice Get locked tokens value in a specified moment in time
    * @param _owner Tokens owner
    * @param _blockNumber Block number for checking
    **/
    function getLockedTokens(address _owner, uint256 _blockNumber)
        public constant returns (uint256)
    {
        if (tokenInfo[_owner].releaseBlock <= _blockNumber) {
            return 0;
        } else {
            return tokenInfo[_owner].lockedValue;
        }
    }

    /**
    * @notice Get locked tokens value for all owners in a specified moment in time
    * @param _blockNumber Block number for checking
    **/
    function getAllLockedTokens(uint256 _blockNumber)
        public constant returns (uint256 result)
    {
        var current = tokenOwners.step(0x0, true);
        while (current != 0x0) {
            result += getLockedTokens(current, _blockNumber);
            current = tokenOwners.step(current, true);
        }
    }

    /**
    * @notice Get locked tokens value for owner
    * @param _owner Tokens owner
    **/
    function getLockedTokens(address _owner)
        public constant returns (uint256)
    {
        return getLockedTokens(_owner, block.number);
    }

    /*
       Fixedstep in cumsum
       @start   Starting point
       @delta   How much to step

      |-------->*--------------->*---->*------------->|
                |                      ^
                |                      o_stop
                |
                |       _delta
                |---------------------------->|
                |
                |                       o_shift
                |                      |----->|
       */
      // _blockNumber?
    function findCumSum(address _start, uint256 _delta)
        public constant returns (address o_stop, uint256 o_shift)
    {
        uint256 distance = 0;
        uint256 lockedTokens = 0;
        var current = _start;

        if (current == 0x0)
            current = tokenOwners.step(current, true);

        while (true) {
            lockedTokens = getLockedTokens(current);
            if (_delta < distance + lockedTokens) {
                o_stop = current;
                o_shift = _delta - distance;
                break;
            } else {
                distance += lockedTokens;
                current = tokenOwners.step(current, true);
            }
        }
    }

    /**
    * @notice Get locked tokens value for sender at the time of the last minted block
    **/
    function getLastLockedTokens()
        internal constant returns (uint256)
    {
        return getLockedTokens(msg.sender, tokenInfo[msg.sender].lastMintedBlock);
    }

    /**
    * @notice Get locked tokens value for all owners
    **/
    function getAllLockedTokens()
        public constant returns (uint256 result)
    {
        return getAllLockedTokens(block.number);
    }

    /**
    * @notice Mint tokens for sender if he locked his tokens
    **/
    function mint() {
        require(getLastLockedTokens() != 0);
        var lockedBlocks = Math.min256(block.number, tokenInfo[msg.sender].releaseBlock) -
            tokenInfo[msg.sender].lastMintedBlock;
        var (amount, decimals) = mint(
            msg.sender,
            tokenInfo[msg.sender].lockedValue,
            lockedBlocks,
            tokenInfo[msg.sender].decimals);
        if (amount != 0) {
            tokenInfo[msg.sender].lastMintedBlock = block.number;
            tokenInfo[msg.sender].decimals = decimals;
        }
    }

    /**
    * @notice Penalize token owner
    * @param _user Token owner
    * @param _value Amount of tokens that will be confiscated
    **/
    function penalize(address _user, uint256 _value)
        onlyOwner
        public returns (bool success)
    {
        require(getLockedTokens(_user) >= _value);
        tokenInfo[_user].value = tokenInfo[_user].value.sub(_value);
        tokenInfo[_user].lockedValue = tokenInfo[_user].lockedValue.sub(_value);
        token.burn(_value);
        return true;
    }
}