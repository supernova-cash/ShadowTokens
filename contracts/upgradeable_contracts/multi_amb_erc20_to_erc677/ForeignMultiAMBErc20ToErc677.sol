pragma solidity 0.4.24;

import "openzeppelin-solidity/contracts/token/ERC20/DetailedERC20.sol";
import "./BasicMultiAMBErc20ToErc677.sol";
import "./ForeignFeeManagerMultiAMBErc20ToErc677.sol";
import "../../libraries/TokenReader.sol";

/**
 * @title ForeignMultiAMBErc20ToErc677
 * @dev Foreign side implementation for multi-erc20-to-erc677 mediator intended to work on top of AMB bridge.
 * It is designed to be used as an implementation contract of EternalStorageProxy contract.
 */
contract ForeignMultiAMBErc20ToErc677 is BasicMultiAMBErc20ToErc677, ForeignFeeManagerMultiAMBErc20ToErc677 {
    bytes4 internal constant DEPLOY_AND_HANDLE_BRIDGE_TOKENS = 0x2ae87cdd; // deployAndHandleBridgedTokens(address,string,string,uint8,address,uint256)

    /**
    * @dev Stores the initial parameters of the mediator.
    * @param _bridgeContract the address of the AMB bridge contract.
    * @param _mediatorContract the address of the mediator contract on the other network.
    * @param _dailyLimitMaxPerTxMinPerTxArray array with limit values for the assets to be bridged to the other network.
    *   [ 0 = dailyLimit, 1 = maxPerTx, 2 = minPerTx ]
    * @param _executionDailyLimitExecutionMaxPerTxArray array with limit values for the assets bridged from the other network.
    *   [ 0 = executionDailyLimit, 1 = executionMaxPerTx ]
    * @param _requestGasLimit the gas limit for the message execution.
    * @param _owner address of the owner of the mediator contract.
    * @param _rewardAddreses list of reward addresses, between whom fees will be distributed.
    * @param _fees array with initial fees for both bridge firections.
    *   [ 0 = homeToForeignFee, 1 = foreignToHomeFee ]
    */
    function initialize(
        address _bridgeContract,
        address _mediatorContract,
        uint256[3] _dailyLimitMaxPerTxMinPerTxArray, // [ 0 = _dailyLimit, 1 = _maxPerTx, 2 = _minPerTx ]
        uint256[2] _executionDailyLimitExecutionMaxPerTxArray, // [ 0 = _executionDailyLimit, 1 = _executionMaxPerTx ]
        uint256 _requestGasLimit,
        address _owner,
        address[] _rewardAddreses,
        uint256[2] _fees // [ 0 = homeToForeignFee, 1 = foreignToHomeFee ]
    ) external onlyRelevantSender returns (bool) {
        require(!isInitialized());
        require(_owner != address(0));

        _setBridgeContract(_bridgeContract);
        _setMediatorContractOnOtherSide(_mediatorContract);
        _setLimits(address(0), _dailyLimitMaxPerTxMinPerTxArray);
        _setExecutionLimits(address(0), _executionDailyLimitExecutionMaxPerTxArray);
        _setRequestGasLimit(_requestGasLimit);
        setOwner(_owner);
        if (_rewardAddreses.length > 0) {
            _setRewardAddressList(_rewardAddreses);
        }
        _setFee(HOME_TO_FOREIGN_FEE, address(0), _fees[0]);
        _setFee(FOREIGN_TO_HOME_FEE, address(0), _fees[1]);
        setInitialize();

        return isInitialized();
    }

    /**
     * @dev Executes action on the request to withdraw tokens relayed from the other network
     * @param _token address of the token contract
     * @param _recipient address of tokens receiver
     * @param _value amount of bridged tokens
     */
    function executeActionOnBridgedTokens(address _token, address _recipient, uint256 _value) internal {
        bytes32 _messageId = messageId();
        uint256 valueToTransfer = _value;
        uint256 fee = _distributeFee(HOME_TO_FOREIGN_FEE, _token, valueToTransfer);
        if (fee > 0) {
            emit FeeDistributed(fee, _token, _messageId);
            valueToTransfer = valueToTransfer.sub(fee);
        }
        ERC677(_token).transfer(_recipient, valueToTransfer);
        _setMediatorBalance(_token, mediatorBalance(_token).sub(_value));
        emit TokensBridged(_token, _recipient, valueToTransfer, _messageId);
    }

    /**
    * @dev ERC677 transfer callback function.
    * @param _from address of tokens sender.
    * @param _value amount of transferred tokens.
    * @param _data additional transfer data, can be used for passing alternative receiver address.
    */
    function onTokenTransfer(address _from, uint256 _value, bytes _data) public returns (bool) {
        if (!lock()) {
            ERC677 token = ERC677(msg.sender);
            bridgeSpecificActionsOnTokenTransfer(token, _from, _value, _data);
        }
        return true;
    }

    /**
    * @dev Validates that the token amount is inside the limits, calls transferFrom to transfer the tokens to the contract
    * and invokes the method to burn/lock the tokens and unlock/mint the tokens on the other network.
    * The user should first call Approve method of the ERC677 token.
    * @param token bridge token contract address.
    * @param _from address that will transfer the tokens to be locked.
    * @param _receiver address that will receive the native tokens on the other network.
    * @param _value amount of tokens to be transferred to the other network.
    */
    function _relayTokens(ERC677 token, address _from, address _receiver, uint256 _value) internal {
        // This lock is to prevent calling passMessage twice if a ERC677 token is used.
        // When transferFrom is called, after the transfer, the ERC677 token will call onTokenTransfer from this contract
        // which will call passMessage.
        require(!lock());
        address to = address(this);

        setLock(true);
        token.transferFrom(_from, to, _value);
        setLock(false);
        bridgeSpecificActionsOnTokenTransfer(token, _from, _value, abi.encodePacked(_receiver));
    }

    /**
     * @dev Executes action on deposit of bridged tokens
     * @param _token address of the token contract
     * @param _from address of tokens sender
     * @param _value requsted amount of bridged tokens
     * @param _data alternative receiver, if specified
     */
    function bridgeSpecificActionsOnTokenTransfer(ERC677 _token, address _from, uint256 _value, bytes _data) internal {
        if (lock()) return;

        bool isKnownToken = isTokenRegistered(_token);
        if (!isKnownToken) {
            string memory name = TokenReader.readName(_token);
            string memory symbol = TokenReader.readSymbol(_token);
            uint8 decimals = uint8(TokenReader.readDecimals(_token));

            require(bytes(name).length > 0 || bytes(symbol).length > 0);

            _initializeTokenBridgeLimits(_token, decimals);
            _setFee(HOME_TO_FOREIGN_FEE, _token, getFee(HOME_TO_FOREIGN_FEE, address(0)));
            _setFee(FOREIGN_TO_HOME_FEE, _token, getFee(FOREIGN_TO_HOME_FEE, address(0)));
        }

        require(withinLimit(_token, _value));
        addTotalSpentPerDay(_token, getCurrentDay(), _value);

        bytes memory data;
        address receiver = chooseReceiver(_from, _data);
        uint256 valueToBridge = _value;
        uint256 fee = _distributeFee(FOREIGN_TO_HOME_FEE, _token, valueToBridge);
        if (fee > 0) {
            emit FeeDistributed(fee, _token, _messageId);
            valueToBridge = valueToBridge.sub(fee);
        }

        if (isKnownToken) {
            data = abi.encodeWithSelector(this.handleBridgedTokens.selector, _token, receiver, valueToBridge);
        } else {
            data = abi.encodeWithSelector(
                DEPLOY_AND_HANDLE_BRIDGE_TOKENS,
                _token,
                name,
                symbol,
                decimals,
                receiver,
                valueToBridge
            );
        }

        // avoid stack too deep error by using existing variable
        fee = mediatorBalance(_token).add(valueToBridge);
        _setMediatorBalance(_token, fee);

        bytes32 _messageId = bridgeContract().requireToPassMessage(
            mediatorContractOnOtherSide(),
            data,
            requestGasLimit()
        );

        setMessageToken(_messageId, _token);
        setMessageValue(_messageId, valueToBridge);
        setMessageRecipient(_messageId, _from);
    }

    /**
    * @dev Unlock back the amount of tokens that were bridged to the other network but failed.
    * @param _token address that bridged token contract.
    * @param _recipient address that will receive the tokens.
    * @param _value amount of tokens to be received.
    */
    function executeActionOnFixedTokens(address _token, address _recipient, uint256 _value) internal {
        _setMediatorBalance(_token, mediatorBalance(_token).sub(_value));
        ERC677(_token).transfer(_recipient, _value);
    }

    /**
    * @dev Allows to send to the other network the amount of locked tokens that can be forced into the contract
    * without the invocation of the required methods. (e. g. regular transfer without a call to onTokenTransfer)
    * @param _token address of the token contract.
    * @param _receiver the address that will receive the tokens on the other network.
    */
    function fixMediatorBalance(address _token, address _receiver) public onlyIfUpgradeabilityOwner {
        require(isTokenRegistered(_token));
        uint256 balance = ERC677(_token).balanceOf(address(this));
        uint256 expectedBalance = mediatorBalance(_token);
        require(balance > expectedBalance);
        uint256 diff = balance - expectedBalance;
        uint256 available = maxAvailablePerTx(_token);
        require(available > 0);
        if (diff > available) {
            diff = available;
        }
        addTotalSpentPerDay(_token, getCurrentDay(), diff);
        _setMediatorBalance(_token, expectedBalance.add(diff));

        bytes memory data = abi.encodeWithSelector(this.handleBridgedTokens.selector, _token, _receiver, diff);

        bytes32 _messageId = bridgeContract().requireToPassMessage(
            mediatorContractOnOtherSide(),
            data,
            requestGasLimit()
        );

        setMessageToken(_messageId, _token);
        setMessageValue(_messageId, diff);
        setMessageRecipient(_messageId, _receiver);
    }

    /**
    * @dev Tells the expected token balance of the contract.
    * @param _token address of token contract.
    * @return the current tracked token balance of the contract.
    */
    function mediatorBalance(address _token) public view returns (uint256) {
        return uintStorage[keccak256(abi.encodePacked("mediatorBalance", _token))];
    }

    /**
    * @dev Updates expected token balance of the contract.
    * @param _token address of token contract.
    * @param _balance the new token balance of the contract.
    */
    function _setMediatorBalance(address _token, uint256 _balance) internal {
        uintStorage[keccak256(abi.encodePacked("mediatorBalance", _token))] = _balance;
    }
}