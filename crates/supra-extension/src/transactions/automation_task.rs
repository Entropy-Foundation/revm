use crate::errors::SupraExtensionError;
use crate::supra_contract_bindings::supra_contracts_bindings::CommonUtils::{
    TaskDetails,
};
use crate::transactions::automated_transaction::{
    AutomatedTransaction, AutomatedTransactionDetails, AutomatedTransactionType,
};
use crate::value_or_error;
use alloy::eips::eip2930::{AccessList, AccessListItem};
use alloy::primitives::{Address, ChainId, B256};
use alloy_sol_types::SolType;
use primitives::{Bytes, U256};

type AccessListItemTy = (
    alloy_sol_types::sol_data::Address,
    alloy_sol_types::sol_data::Array<alloy_sol_types::sol_data::FixedBytes<32>>,
);
type AccessListTy = alloy_sol_types::sol_data::Array<AccessListItemTy>;
type ExpandedPayloadTy = (
    alloy_sol_types::sol_data::Uint<256>,
    alloy_sol_types::sol_data::Address,
    alloy_sol_types::sol_data::Bytes,
    AccessListTy,
);

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum BuildResult {
    Success(AutomatedTransactionDetails),
    GasPriceLimitExceeded {
        gas_price: u128,
        gas_price_cap: u128,
    },
}

pub struct AutomatedTransactionBuilder {
    block_height: Option<u64>,
    chain_id: Option<ChainId>,
    gas_limit: Option<u64>,
    gas_price: Option<u128>,
    gas_price_cap: u128,
    registration_hash: Option<B256>,
    task_index: Option<u64>,
    expiry_timestamp: Option<u64>,
    owner: Option<Address>,
    tpy: Option<AutomatedTransactionType>,
    priority: Option<u64>,

    to: Option<Address>,
    value: Option<U256>,
    access_list: Option<AccessList>,
    input: Option<Bytes>,
}

impl AutomatedTransactionBuilder {
    pub fn new(gas_price_cap: u128) -> Self {
        Self {
            block_height: None,
            chain_id: None,
            gas_limit: None,
            gas_price: None,
            gas_price_cap,
            registration_hash: None,
            task_index: None,
            expiry_timestamp: None,
            owner: None,
            tpy: None,
            priority: None,
            to: None,
            value: None,
            access_list: None,
            input: None,
        }
    }

    pub fn block_height(mut self, block_height: u64) -> Self {
        self.block_height = Some(block_height);
        self
    }

    pub fn chain_id(mut self, chain_id: ChainId) -> Self {
        self.chain_id = Some(chain_id);
        self
    }

    pub fn gas_limit(mut self, gas_limit: u64) -> Self {
        self.gas_limit = Some(gas_limit);
        self
    }
    pub fn gas_price(mut self, gas_price: u128) -> Self {
        self.gas_price = Some(gas_price);
        self
    }
    pub fn gas_price_cap(mut self, gas_price_cap: u128) -> Self {
        self.gas_price_cap = gas_price_cap;
        self
    }
    pub fn registration_hash(mut self, registration_hash: B256) -> Self {
        self.registration_hash = Some(registration_hash);
        self
    }
    pub fn task_index(mut self, task_index: u64) -> Self {
        self.task_index = Some(task_index);
        self
    }
    pub fn expiry_timestamp(mut self, expiry_timestamp: u64) -> Self {
        self.expiry_timestamp = Some(expiry_timestamp);
        self
    }
    pub fn owner(mut self, owner: Address) -> Self {
        self.owner = Some(owner);
        self
    }
    pub fn tpy(mut self, tpy: AutomatedTransactionType) -> Self {
        self.tpy = Some(tpy);
        self
    }
    pub fn priority(mut self, priority: u64) -> Self {
        self.priority = Some(priority);
        self
    }
    pub fn to(mut self, to: Address) -> Self {
        self.to = Some(to);
        self
    }
    pub fn value(mut self, value: U256) -> Self {
        self.value = Some(value);
        self
    }
    pub fn access_list(mut self, access_list: AccessList) -> Self {
        self.access_list = Some(access_list);
        self
    }
    pub fn input(mut self, input: Bytes) -> Self {
        self.input = Some(input);
        self
    }
    pub fn build(self) -> Result<BuildResult, SupraExtensionError> {
        let Self {
            block_height,
            chain_id,
            gas_limit,
            gas_price,
            gas_price_cap,
            registration_hash,
            task_index,
            expiry_timestamp: _,
            owner,
            tpy,
            priority,
            to,
            value,
            access_list,
            input,
        } = self;
        let block_height =
            value_or_error!(AutomatedTransactionBuilder, "block_height", block_height);
        let chain_id = value_or_error!(AutomatedTransactionBuilder, "chain_id", chain_id);
        let gas_limit = value_or_error!(AutomatedTransactionBuilder, "gas_limit", gas_limit);
        let gas_price = value_or_error!(AutomatedTransactionBuilder, "gasPrice", gas_price);
        let registration_hash = value_or_error!(
            AutomatedTransactionBuilder,
            "registration_hash",
            registration_hash
        );
        let task_index = value_or_error!(AutomatedTransactionBuilder, "task_index", task_index);
        let owner = value_or_error!(AutomatedTransactionBuilder, "owner", owner);
        let tpy = value_or_error!(AutomatedTransactionBuilder, "type", tpy);
        let priority = value_or_error!(AutomatedTransactionBuilder, "priority", priority);
        let to = value_or_error!(AutomatedTransactionBuilder, "to", to);
        let value = value_or_error!(AutomatedTransactionBuilder, "value", value);
        let access_list = value_or_error!(AutomatedTransactionBuilder, "access_list", access_list);
        let input = value_or_error!(AutomatedTransactionBuilder, "input", input);
        if gas_price_cap < gas_price {
            return Ok(BuildResult::GasPriceLimitExceeded {
                gas_price,
                gas_price_cap,
            });
        }
        let txn = AutomatedTransaction {
            block_height,
            registration_hash,
            sender: owner,
            txn_type: tpy,
            chain_id,
            nonce: task_index,
            gas_limit,
            max_fee_per_gas: gas_price,
            to,
            value,
            access_list,
            input,
        };
        Ok(BuildResult::Success(AutomatedTransactionDetails {
            txn,
            priority,
        }))
    }
}

impl TryFrom<TaskDetails> for AutomatedTransactionBuilder {
    type Error = SupraExtensionError;

    fn try_from(value: TaskDetails) -> Result<Self, Self::Error> {
        let TaskDetails {
            maxGasAmount,
            gasPriceCap,
            automationFeeCapForCycle: _,
            lockedFeeForNextCycle: _,
            txHash,
            taskIndex,
            registrationTime: _,
            expiryTime,
            owner,
            state: _,
            payloadTx,
            auxData: _,
        } = value;
        // TODO check if task state is not active return an error.

        let (value, to, input, access_list) = ExpandedPayloadTy::abi_decode(payloadTx.as_ref())?;
        let access_items = access_list
            .into_iter()
            .map(|(address, storage_keys)| AccessListItem {
                address,
                storage_keys,
            })
            .collect();
        let builder = Self::new(gasPriceCap)
            .gas_limit(maxGasAmount as u64)
            .gas_price_cap(gasPriceCap)
            .registration_hash(txHash)
            .task_index(taskIndex)
            .expiry_timestamp(expiryTime)
            .owner(owner)
            .to(to)
            .value(value)
            .input(input)
            .access_list(AccessList(access_items));
        Ok(builder)
    }
}


#[cfg(test)]
mod test {
    use alloy::hex;
    use super::*;
    #[test]
    fn check_decode() {
        let encoded = hex!("00000000000000000000000000000000000000000000000000000000000000000000000000000000000000006b182f1488e8efeb2eb298155ed5bd7ff8a14042000000000000000000000000000000000000000000000000000000000000008000000000000000000000000000000000000000000000000000000000000000e000000000000000000000000000000000000000000000000000000000000000242e1a7d4d0000000000000000000000000000000000000000000000000000000000000064000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000004000000000000000000000000000000000000000000000000000000000000000e00000000000000000000000000000000000000000000000000000000000001111000000000000000000000000000000000000000000000000000000000000004000000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000022220000000000000000000000000000000000000000000000000000000000000040000000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000001");
        let (value, to, input, access_list) = ExpandedPayloadTy::abi_decode(&encoded).unwrap();
        println!("to: {:?}", to);
        println!("value: {:?}", value);
        println!("access_list: {:?}", access_list);
        println!("input: {:?}", input);
    }
}
