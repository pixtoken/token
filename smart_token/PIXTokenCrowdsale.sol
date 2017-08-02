pragma solidity ^0.4.4;

/**
 * Overflow aware uint math functions.
 *
 * Inspired by https://github.com/MakerDAO/maker-otc/blob/master/contracts/simple_market.sol
 */
contract SafeMath {
  //internals

  function safeMul(uint a, uint b) internal returns (uint) {
    uint c = a * b;
    require(a == 0 || c / a == b);
    return c;
  }

  function safeSub(uint a, uint b) internal returns (uint) {
    require(b <= a);
    return a - b;
  }

  function safeAdd(uint a, uint b) internal returns (uint) {
    uint c = a + b;
    require(c>=a && c>=b);
    return c;
  }

  function safeDiv(uint a, uint b) internal returns (uint) {
    require(b > 0);
    uint c = a / b;
    require(a == b * c + a % b);
    return c;
  }
}


/**
 * ERC 20 token
 *
 * https://github.com/ethereum/EIPs/issues/20
 */
contract Token {

    /// @return total amount of tokens
    function totalSupply() constant returns (uint256 supply) {}

    /// @param _owner The address from which the balance will be retrieved
    /// @return The balance
    function balanceOf(address _owner) constant returns (uint256 balance) {}

    /// @notice send `_value` token to `_to` from `msg.sender`
    /// @param _to The address of the recipient
    /// @param _value The amount of token to be transferred
    /// @return Whether the transfer was successful or not
    function transfer(address _to, uint256 _value) returns (bool success) {}

    /// @notice send `_value` token to `_to` from `_from` on the condition it is approved by `_from`
    /// @param _from The address of the sender
    /// @param _to The address of the recipient
    /// @param _value The amount of token to be transferred
    /// @return Whether the transfer was successful or not
    function transferFrom(address _from, address _to, uint256 _value) returns (bool success) {}

    /// @notice `msg.sender` approves `_addr` to spend `_value` tokens
    /// @param _spender The address of the account able to transfer the tokens
    /// @param _value The amount of wei to be approved for transfer
    /// @return Whether the approval was successful or not
    function approve(address _spender, uint256 _value) returns (bool success) {}

    /// @param _owner The address of the account owning tokens
    /// @param _spender The address of the account able to transfer the tokens
    /// @return Amount of remaining tokens allowed to spent
    function allowance(address _owner, address _spender) constant returns (uint256 remaining) {}

    event Transfer(address indexed _from, address indexed _to, uint256 _value);
    event Approval(address indexed _owner, address indexed _spender, uint256 _value);

}

/**
 * ERC 20 token
 *
 * https://github.com/ethereum/EIPs/issues/20
 */
contract StandardToken is Token {

    /**
     * Reviewed:
     * - Interger overflow = OK, checked
     */
    function transfer(address _to, uint256 _value) returns (bool success) {
        //Default assumes totalSupply can't be over max (2^256 - 1).
        //If your token leaves out totalSupply and can issue more tokens as time goes on, you need to check if it doesn't wrap.
        //Replace the if with this one instead.
        if (balances[msg.sender] >= _value && balances[_to] + _value > balances[_to]) {
        //if (balances[msg.sender] >= _value && _value > 0) {
            balances[msg.sender] -= _value;
            balances[_to] += _value;
            Transfer(msg.sender, _to, _value);
            return true;
        } else { return false; }
    }

    function transferFrom(address _from, address _to, uint256 _value) returns (bool success) {
        //same as above. Replace this line with the following if you want to protect against wrapping uints.
        if (balances[_from] >= _value && allowed[_from][msg.sender] >= _value && balances[_to] + _value > balances[_to]) {
        //if (balances[_from] >= _value && allowed[_from][msg.sender] >= _value && _value > 0) {
            balances[_to] += _value;
            balances[_from] -= _value;
            allowed[_from][msg.sender] -= _value;
            Transfer(_from, _to, _value);
            return true;
        } else { return false; }
    }

    function balanceOf(address _owner) constant returns (uint256 balance) {
        return balances[_owner];
    }

    function approve(address _spender, uint256 _value) returns (bool success) {
        allowed[msg.sender][_spender] = _value;
        Approval(msg.sender, _spender, _value);
        return true;
    }

    function allowance(address _owner, address _spender) constant returns (uint256 remaining) {
      return allowed[_owner][_spender];
    }

    mapping(address => uint256) balances;

    mapping (address => mapping (address => uint256)) allowed;

    uint256 public totalSupply;
}


/**
 * PIX crowdsale ICO contract.
 *
 * Security criteria evaluated against http://ethereum.stackexchange.com/questions/8551/methodological-security-review-of-a-smart-contract
 *
 *
 */
contract PIXToken is StandardToken, SafeMath {

    string public name = "PIX Token";
    string public symbol = "PIX";
    uint public decimals = 18;

    // Initial founder address (set in constructor)
    // All deposited ETH will be instantly forwarded to this address.
    // Address is a multisig wallet.
    address public founder = 0x0;

    // signer address (for clickwrap agreement)
    // see function() {} for comments
    address public signer = 0x0;

    /* THE plan
    we will have 5 stages:
    1. pre sale. there is a limited number of PIX tokens available for pre sale at a given price in eth. the bonus is 20% and only the founders can buy
    2. day 1. another limited number, given price and bonus
    3. day 2. another limited number, given price and bonus
    4. day 3-10. another limited number, given price and bonus
    5. after the sale has ended, following lockups take place:
        - reserve tokens are 30% of total token amount, available 1/4 after 1 year, 1/4 after 2, 1/4 after 3, 1/4 after 4
        - team and partner tokens are 20%, available 1/4 1 month after the sale, 1/4 after 1 year, 1/4 after 2, 1/4 after 3
        - crowdsale tokens are publicly trade-able 1 month crowd sale
    */

    uint public secsPerBlock = 15;
    uint public secsInADay = 86400;
    enum State { PreSale, Day1, Day2, Day3, Lockup, Running, Halted } // the states through which this contract goes



    uint public capPreSale = 15 * 10**6;  // 15M USD cap for presale, this subtracts from day1 cap
    uint public capDay1 = 20 * 10**6;  // 20M USD cap for day 1
    uint public capDay2 = 20 * 10**6;  // 20M USD cap for day 2
    uint public capDay3 = 20 * 10**6;  // 20M USD cap for day 3 - 10

    uint public raisePreSale = 0;  // usd raised in pre-sale
    uint public raiseDay1 = 0;  // usd raised on day 1
    uint public raiseDay2 = 0;  // usd raised on day 2
    uint public raiseDay3 = 0;  // usd raised on day 3 - 10

    uint public blockStartDay1;
    uint public blockStartDay2;
    uint public blockStartDay3;
    uint public blockEnd;
    uint public blockAfter1Month;
    uint public blockAfter1Year;
    uint public blockAfter2Year;
    uint public blockAfter3Year;
    uint public blockAfter4Year;

    bool allocated1Month = false;
    bool allocated1Year = false;
    bool allocated2Year = false;
    bool allocated3Year = false;
    bool allocated4Year = false;

    uint public totalTokensSale = 500000000; //total number of tokens we plan to sell in the ico, excluding bonuses and reserve
    uint public totalTokensReserve = 300000000;
    uint public totalTokensCompany = 200000000;

    bool public halted = false; //the founder address can set this to true to halt the crowdsale due to emergency

    uint public centsPerEth = 23000;

    event Buy(address indexed sender, uint eth, uint fbt);
    event Withdraw(address indexed sender, address to, uint eth);
    event AllocateTokens(address indexed sender);

    function PIXToken(address founderInput, address signerInput, uint blockStartDay1Input) {
        founder = founderInput;
        signer = signerInput;
        blockStartDay1 = blockStartDay1Input;
        uint blocksPerDay = secsInADay / secsPerBlock;
        blockStartDay2 = blockStartDay1 + 1 * blocksPerDay;
        blockStartDay3 = blockStartDay1 + 2 * blocksPerDay;
        blockEnd = blockStartDay1 + 9 * blocksPerDay;
        blockAfter1Month = blockEnd + 31 * blocksPerDay;
        blockAfter1Year = blockEnd + 356 * blocksPerDay;
        blockAfter2Year = blockEnd + 2 * 356 * blocksPerDay;
        blockAfter3Year = blockEnd + 3 * 356 * blocksPerDay;
        blockAfter4Year = blockEnd + 4 * 356 * blocksPerDay;
    }

    function setETHUSDRate(uint centsPerEthInput) {
        require(msg.sender==founder);
        centsPerEth = centsPerEthInput;
    }

    function getCurrentState() constant returns (State) {
        if(halted) return State.Halted;
        else if(block.number < blockStartDay1) return State.PreSale;
        else if(block.number < blockStartDay2) return State.Day1;
        else if(block.number < blockStartDay3) return State.Day2;
        else if(block.number < blockEnd) return State.Day3;
        else return State.Running;
    }

    function getCurrentBonusInPercent() constant returns (uint) {
        State s = getCurrentState();
        if (s == State.Halted) throw;
        else if(s == State.PreSale) return 20;
        else if(s == State.Day1) return 15;
        else if(s == State.Day2) return 10;
        else if(s == State.Day3) return 5;
        else return 0;
    }

    function getTokenPriceInWEI() constant returns (uint) {
        uint totalRaiseUSD = capDay1 + capDay2 + capDay3;
        uint ethNeeded = (10 ** 18) * 100 * totalRaiseUSD / centsPerEth;  // times 100 because eth price is in cents, times 10**18 to get wei
        return ethNeeded / totalTokensSale;
    }

    // Buy entry point
    function buy(uint8 v, bytes32 r, bytes32 s) {
        buyRecipient(msg.sender, v, r, s);
    }

    /**
     * Main token buy function.
     *
     * Buy for the sender itself or buy on the behalf of somebody else (third party address).
     *
     * Security review
     *
     * - Integer math: ok - using SafeMath
     *
     * - halt flag added - ok
     *
     * Applicable tests:
     *
     * - Test halting, buying, and failing
     * - Test buying on behalf of a recipient
     * - Test buy
     * - Test unhalting, buying, and succeeding
     * - Test buying after the sale ends
     *
     */
    function buyRecipient(address recipient, uint8 v, bytes32 r, bytes32 s) {
        bytes32 hash = sha256(msg.sender);
        require (ecrecover(hash,v,r,s) == signer);
        State st = getCurrentState();
        uint usdCentsRaise = safeDiv(safeMul(msg.value, centsPerEth), 10 ** 18); //divide by 10 ** 18 because msg.value is in wei

        if(st == State.PreSale)
        {
            require(msg.sender==founder); //only founder can buy in pre-sale, on behalf of our pre-sale customers
            raisePreSale = safeAdd(raisePreSale, usdCentsRaise); //add current raise to pre-sell amount
            require(raisePreSale < 15 * 10**6 * 100); //ensure pre-sale cap, 15m usd * 100 so we have cents
        }
        else if (st == State.Day1)
        {
            raiseDay1 = safeAdd(raiseDay1, usdCentsRaise); //add current raise to pre-sell amount
            require(raiseDay1 < (20 * 10**6 * 100 - raisePreSale)); //ensure day 1 cap, which is lower by the amount we pre-sold 
        }
        else if (st == State.Day2)
        {
            raiseDay2 = safeAdd(raiseDay2, usdCentsRaise); //add current raise to pre-sell amount
            require(raiseDay2 < 20 * 10**6 * 100); //ensure day 2 cap
        }
        else if (st == State.Day3)
        {
            raiseDay3 = safeAdd(raiseDay3, usdCentsRaise); //add current raise to pre-sell amount
            require(raiseDay3 < 20 * 10**6 * 100); //ensure day 3 cap
        }
        else throw; // sale has ended

        uint tokens = safeDiv(msg.value, getTokenPriceInWEI()); //calculate amount of tokens
        uint bonus = safeDiv(safeMul(tokens, getCurrentBonusInPercent()), 100); //calculate bonus
        
        if(st == State.PreSale)
            totalTokensCompany = safeSub(totalTokensCompany, bonus); //the pre-sale bonuses go from the company tokens

        uint totalTokens = safeAdd(tokens, bonus);

        balances[recipient] = safeAdd(balances[recipient], totalTokens);
        totalSupply = safeAdd(totalSupply, totalTokens);

        // TODO: Is there a pitfall of forwarding message value like this
        // TODO: Different address for founder deposits and founder operations (halt, unhalt)
        // as founder opeations might be easier to perform from normal geth account
        if (!founder.call.value(msg.value)()) throw; //immediately send Ether to founder address

        Buy(recipient, msg.value, totalTokens);
    }

    /**
     * Allocate reserve and team tokens, when the time comes.
     *
     * allocateBountyAndEcosystemTokens() must be calld first.
     *
     * Security review
     *
     * - Integer math: ok - only called once with fixed parameters
     *
     * Applicable tests:
     *
     * - Test allocation
     * - Test allocation twice, multiple times
     *
     */
    function allocateReserveAndFounderTokens() {
        require(msg.sender==founder);
        require(getCurrentState() == State.Running);

        uint tokens = 0;
        if(block.number > blockAfter1Month && !allocated1Month)
        {
            allocated1Month = true;
            tokens = safeDiv(totalTokensCompany, 4);
            balances[founder] = safeAdd(balances[founder], tokens);
            totalSupply = safeAdd(totalSupply, tokens);
        }
        else if(block.number > blockAfter1Year && !allocated1Year)
        {
            allocated1Year = true;
            tokens = safeDiv(totalTokensCompany, 4);
            balances[founder] = safeAdd(balances[founder], tokens);
            totalSupply = safeAdd(totalSupply, tokens);
            tokens = safeDiv(totalTokensReserve, 4);
            balances[founder] = safeAdd(balances[founder], tokens);
            totalSupply = safeAdd(totalSupply, tokens);
        }
        else if(block.number > blockAfter2Year && !allocated2Year)
        {
            allocated2Year = true;
            tokens = safeDiv(totalTokensCompany, 4);
            balances[founder] = safeAdd(balances[founder], tokens);
            totalSupply = safeAdd(totalSupply, tokens);
            tokens = safeDiv(totalTokensReserve, 4);
            balances[founder] = safeAdd(balances[founder], tokens);
            totalSupply = safeAdd(totalSupply, tokens);
        }
        else if(block.number > blockAfter3Year && !allocated3Year)
        {
            allocated3Year = true;
            tokens = safeDiv(totalTokensCompany, 4);
            balances[founder] = safeAdd(balances[founder], tokens);
            totalSupply = safeAdd(totalSupply, tokens);
            tokens = safeDiv(totalTokensReserve, 4);
            balances[founder] = safeAdd(balances[founder], tokens);
            totalSupply = safeAdd(totalSupply, tokens);
        }
        else if(block.number > blockAfter4Year && !allocated4Year)
        {
            allocated4Year = true;
            tokens = safeDiv(totalTokensReserve, 4);
            balances[founder] = safeAdd(balances[founder], tokens);
            totalSupply = safeAdd(totalSupply, tokens);
        }
        else throw;

        AllocateTokens(msg.sender);
    }

    /**
     * Emergency Stop ICO.
     *
     *  Applicable tests:
     *
     * - Test unhalting, buying, and succeeding
     */
    function halt() {
        require(msg.sender==founder);
        halted = true;
    }

    function unhalt() {
        require(msg.sender==founder);
        halted = false;
    }

    /**
     * Change founder address (where ICO ETH is being forwarded).
     *
     * Applicable tests:
     *
     * - Test founder change by hacker
     * - Test founder change
     * - Test founder token allocation twice
     */
    function changeFounder(address newFounder) {
        require(msg.sender==founder);
        founder = newFounder;
    }

    /**
     * ERC 20 Standard Token interface transfer function
     *
     * Prevent transfers until freeze period is over.
     *
     * Applicable tests:
     *
     * - Test restricted early transfer
     * - Test transfer after restricted period
     */
    function transfer(address _to, uint256 _value) returns (bool success) {
        require(block.number > blockAfter1Month && msg.sender==founder);
        return super.transfer(_to, _value);
    }
    /**
     * ERC 20 Standard Token interface transfer function
     *
     * Prevent transfers until freeze period is over.
     */
    function transferFrom(address _from, address _to, uint256 _value) returns (bool success) {
        require(block.number > blockAfter1Month && msg.sender==founder);
        return super.transferFrom(_from, _to, _value);
    }

    /**
     * Do not allow direct deposits.
     *
     * All crowdsale depositors must have read the legal agreement.
     * This is confirmed by having them signing the terms of service on the website.
     * The give their crowdsale Ethereum source address on the website.
     * Website signs this address using crowdsale private key (different from founders key).
     * buy() takes this signature as input and rejects all deposits that do not have
     * signature you receive after reading terms of service.
     *
     */
    function() {
        throw;
    }

}
