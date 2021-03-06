pragma solidity >=0.5.12 <0.6.0;

import { SafeMathLib } from "./libs/SafeMathLib.sol";


/*
 * ERC20 interface
 * see https://github.com/ethereum/EIPs/issues/20
 */
contract ERC20 {
  uint public totalSupply;
  function balanceOf(address who) public view returns (uint);
  function allowance(address owner, address spender) public view returns (uint);

  function transfer(address to, uint value) public returns (bool ok);
  function transferFrom(address from, address to, uint value) public returns (bool ok);
  function approve(address spender, uint value) public returns (bool ok);

  event Transfer(address indexed from, address indexed to, uint value);
  event Approval(address indexed owner, address indexed spender, uint value);
}

/**
 * Math operations with safety checks
 */
contract SafeMath {
    function safeMul(uint a, uint b) internal pure returns (uint) {
        uint256 c = a * b;
        require(a == 0 || c / a == b);
        return c;
    }

    function safeDiv(uint a, uint b) internal pure returns (uint) {
        require(b > 0, "SafeMath: division by zero");
        uint256 c = a / b;
        // assert(a == b * c + a % b); // There is no case in which this doesn't hold
        return c;
    }

    function safeSub(uint a, uint b) internal pure returns (uint) {
        require(b <= a, "SafeMath: subtraction overflow");
        return a - b;
    }

    function safeAdd(uint a, uint b) internal pure returns (uint) {
        uint256 c = a + b;
        require(c >= a && c >= b, "SafeMath: addition overflow");
        return c;
    }

    function max64(uint64 a, uint64 b) internal pure returns (uint64) {
        return a >= b ? a : b;
    }

    function min64(uint64 a, uint64 b) internal pure returns (uint64) {
        return a < b ? a : b;
    }

    function max256(uint256 a, uint256 b) internal pure returns (uint256) {
        return a >= b ? a : b;
    }

    function min256(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }
}

/*
 * Ownable
 *
 * Base contract with an owner.
 * Provides onlyOwner modifier, which prevents function from running if it is called by anyone other than the owner.
 */
contract Ownable {
    address public owner;

    constructor() public {
        owner = msg.sender;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) {
            revert();
        }
        _;
    }

    function transferOwnership(address newOwner) public onlyOwner {
        if (newOwner != address(0)) {
            owner = newOwner;
        }
    }
}

/**
 * Upgrade agent interface inspired by Lunyr.
 *
 * Upgrade agent transfers tokens to a new contract.
 * Upgrade agent itself can be the token contract, or just a middle man contract doing the heavy lifting.
 */
contract UpgradeAgent {
    uint public originalSupply;

    /** Interface marker */
    function isUpgradeAgent() public pure returns (bool) {
      return true;
    }

    function upgradeFrom(address _from, uint256 _value) public;
}

// Standard ERC20 token to represent MYST token in testnet and local environment.
contract MystToken is ERC20, Ownable, SafeMath {
    using SafeMathLib for uint;

    string public constant name = "Test Mysterium token";
    string public constant symbol = "MYSTT";
    uint8 public constant decimals = 8;

    bool public mintingFinished = false;
    address public upgradeMaster;
    UpgradeAgent public upgradeAgent;                       // The next contract where the tokens will be migrated.
    uint256 public totalUpgraded;                           // How many tokens we have upgraded by now.

    mapping (address => bool) public mintAgents;            // List of agents that are allowed to create new tokens
    mapping(address => uint) balances;                      // Actual balances of token holders
    mapping (address => mapping (address => uint)) allowed; // Approved allowances

    enum UpgradeState {Unknown, NotAllowed, WaitingForAgent, ReadyToUpgrade, Upgrading}

    event Minted(address receiver, uint amount);
    event Upgrade(address indexed _from, address indexed _to, uint256 _value);
    event UpgradeAgentSet(address agent);


    /** Only crowdsale contracts are allowed to mint new tokens */
    modifier onlyMintAgent() {
        if(!mintAgents[msg.sender]) revert();
        _;
    }

    /** Make sure we are not done yet. */
    modifier canMint() {
        if(mintingFinished) revert();
        _;
    }

    /**
     * Fix for the ERC20 short address attack
     * http://vessenes.com/the-erc20-short-address-attack-explained/
     */
    modifier onlyPayloadSize(uint size) {
        if(msg.data.length != size + 4) {
            revert();
        }
        _;
    }

    constructor() public {
        upgradeMaster = msg.sender;
        owner = msg.sender;
        mintAgents[msg.sender] = true;
    }

    function transfer(address _to, uint _value) onlyPayloadSize(2 * 32) public returns (bool success) {
        balances[msg.sender] = safeSub(balances[msg.sender], _value);
        balances[_to] = safeAdd(balances[_to], _value);
        emit Transfer(msg.sender, _to, _value);
        return true;
    }

    function transferFrom(address _from, address _to, uint _value) public returns (bool success) {
        uint _allowance = allowed[_from][msg.sender];

        // Check is not needed because safeSub(_allowance, _value) will already throw if this condition is not met
        // if (_value > _allowance) throw;

        balances[_to] = safeAdd(balances[_to], _value);
        balances[_from] = safeSub(balances[_from], _value);
        allowed[_from][msg.sender] = safeSub(_allowance, _value);
        emit Transfer(_from, _to, _value);
        return true;
    }

    function balanceOf(address _owner) public view returns (uint balance) {
        return balances[_owner];
    }

    function approve(address _spender, uint _value) public returns (bool success) {

        // To change the approve amount you first have to reduce the addresses`
        //  allowance to zero by calling `approve(_spender, 0)` if it is not
        //  already 0 to mitigate the race condition described here:
        //  https://github.com/ethereum/EIPs/issues/20#issuecomment-263524729
        if ((_value != 0) && (allowed[msg.sender][_spender] != 0)) revert();

        allowed[msg.sender][_spender] = _value;
        emit Approval(msg.sender, _spender, _value);
        return true;
    }

    function allowance(address _owner, address _spender) public view returns (uint remaining) {
        return allowed[_owner][_spender];
    }

    /**
     * Atomic increment of approved spending
     *
     * Works around https://github.com/ethereum/EIPs/issues/20#issuecomment-263524729
     */
    function addApproval(address _spender, uint _addedValue) onlyPayloadSize(2 * 32) public returns (bool success) {
        uint oldValue = allowed[msg.sender][_spender];
        allowed[msg.sender][_spender] = safeAdd(oldValue, _addedValue);
        emit Approval(msg.sender, _spender, allowed[msg.sender][_spender]);
        return true;
    }


    /**
     * Atomic decrement of approved spending.
     *
     * Works around https://github.com/ethereum/EIPs/issues/20#issuecomment-263524729
     */
    function subApproval(address _spender, uint _subtractedValue) onlyPayloadSize(2 * 32) public returns (bool success) {
        uint oldVal = allowed[msg.sender][_spender];

        if (_subtractedValue > oldVal) {
            allowed[msg.sender][_spender] = 0;
        } else {
            allowed[msg.sender][_spender] = safeSub(oldVal, _subtractedValue);
        }
        emit Approval(msg.sender, _spender, allowed[msg.sender][_spender]);
        return true;
    }

    /**
     * Create new tokens and allocate them to an address.
     *
     * Only callably by a crowdsale contract (mint agent).
     */
    function mint(address receiver, uint amount) onlyMintAgent canMint public {
        if(amount == 0) {
            revert();
        }

        totalSupply = totalSupply.plus(amount);
        balances[receiver] = balances[receiver].plus(amount);
        emit Minted(receiver, amount);
    }

    /**
     * Owner can allow a crowdsale contract to mint new tokens.
     */
    function setMintAgent(address addr, bool state) onlyOwner canMint public {
        mintAgents[addr] = state;
    }

    /**
     * Allow the token holder to upgrade some of their tokens to a new contract.
     */
    function upgrade(uint256 value) public {
        UpgradeState state = getUpgradeState();
        if(!(state == UpgradeState.ReadyToUpgrade || state == UpgradeState.Upgrading)) {
            // Called in a bad state
            revert();
        }

        // Validate input value.
        if (value == 0) revert();

        balances[msg.sender] = safeSub(balances[msg.sender], value);

        // Take tokens out from circulation
        totalSupply = safeSub(totalSupply, value);
        totalUpgraded = safeAdd(totalUpgraded, value);

        // Upgrade agent reissues the tokens
        upgradeAgent.upgradeFrom(msg.sender, value);
        emit Upgrade(msg.sender, address(upgradeAgent), value);
    }

    /**
     * Set an upgrade agent that handles
     */
    function setUpgradeAgent(address agent) external {
        require(msg.sender == upgradeMaster, "Only a master can designate the next agent");
        require(agent != address(0x0));
        require(getUpgradeState() != UpgradeState.Upgrading, "Upgrade has already begun for an agent");

        upgradeAgent = UpgradeAgent(agent);

        // Bad interface
        if(!upgradeAgent.isUpgradeAgent()) revert();

        // Make sure that token supplies match in source and target
        if (upgradeAgent.originalSupply() != totalSupply) revert();

        emit UpgradeAgentSet(address(upgradeAgent));
    }

    /**
     * Get the state of the token upgrade.
     */
    function getUpgradeState() public view returns(UpgradeState) {
        if(address(upgradeAgent) == address(0x00)) return UpgradeState.WaitingForAgent;
        else if(totalUpgraded == 0) return UpgradeState.ReadyToUpgrade;
        else return UpgradeState.Upgrading;
    }

    /**
     * Change the upgrade master.
     *
     * This allows us to set a new owner for the upgrade mechanism.
     */
    function setUpgradeMaster(address master) public {
        require(master != address(0x0));
        require(msg.sender == upgradeMaster);
        upgradeMaster = master;
    }

}