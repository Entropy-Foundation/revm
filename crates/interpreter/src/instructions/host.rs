use crate::{
    gas::{self, warm_cold_cost, CALL_STIPEND},
    instructions::utility::{IntoAddress, IntoU256},
    interpreter_types::{InputsTr, InterpreterTypes, MemoryTr, RuntimeFlag, StackTr},
    Host, InstructionResult,
};
use core::cmp::min;
use primitives::{
    hardfork::SpecId::*, supra_constants::is_supra_reserved, Bytes, Log, LogData, B256,
    BLOCK_HASH_HISTORY, U256,
};

use crate::InstructionContext;

/// Implements the BALANCE instruction.
///
/// Gets the balance of the given account.
pub fn balance<WIRE: InterpreterTypes, H: Host + ?Sized>(context: InstructionContext<'_, H, WIRE>) {
    popn_top!([], top, context.interpreter);
    let address = top.into_address();
    let Some(balance) = context.host.balance(address) else {
        context
            .interpreter
            .halt(InstructionResult::FatalExternalError);
        return;
    };
    let spec_id = context.interpreter.runtime_flag.spec_id();
    gas!(
        context.interpreter,
        if spec_id.is_enabled_in(BERLIN) {
            warm_cold_cost(balance.is_cold)
        } else if spec_id.is_enabled_in(ISTANBUL) {
            // EIP-1884: Repricing for trie-size-dependent opcodes
            700
        } else if spec_id.is_enabled_in(TANGERINE) {
            400
        } else {
            20
        }
    );
    *top = balance.data;
}

/// EIP-1884: Repricing for trie-size-dependent opcodes
pub fn selfbalance<WIRE: InterpreterTypes, H: Host + ?Sized>(
    context: InstructionContext<'_, H, WIRE>,
) {
    check!(context.interpreter, ISTANBUL);
    //gas!(context.interpreter, gas::LOW);

    let Some(balance) = context
        .host
        .balance(context.interpreter.input.target_address())
    else {
        context
            .interpreter
            .halt(InstructionResult::FatalExternalError);
        return;
    };
    push!(context.interpreter, balance.data);
}

/// Implements the EXTCODESIZE instruction.
///
/// Gets the size of an account's code.
pub fn extcodesize<WIRE: InterpreterTypes, H: Host + ?Sized>(
    context: InstructionContext<'_, H, WIRE>,
) {
    popn_top!([], top, context.interpreter);
    let address = top.into_address();
    let Some(code) = context.host.load_account_code(address) else {
        context
            .interpreter
            .halt(InstructionResult::FatalExternalError);
        return;
    };
    let spec_id = context.interpreter.runtime_flag.spec_id();
    if spec_id.is_enabled_in(BERLIN) {
        gas!(context.interpreter, warm_cold_cost(code.is_cold));
    } else if spec_id.is_enabled_in(TANGERINE) {
        gas!(context.interpreter, 700);
    } else {
        gas!(context.interpreter, 20);
    }

    *top = U256::from(code.len());
}

/// EIP-1052: EXTCODEHASH opcode
pub fn extcodehash<WIRE: InterpreterTypes, H: Host + ?Sized>(
    context: InstructionContext<'_, H, WIRE>,
) {
    check!(context.interpreter, CONSTANTINOPLE);
    popn_top!([], top, context.interpreter);
    let address = top.into_address();
    let Some(code_hash) = context.host.load_account_code_hash(address) else {
        context
            .interpreter
            .halt(InstructionResult::FatalExternalError);
        return;
    };
    let spec_id = context.interpreter.runtime_flag.spec_id();
    if spec_id.is_enabled_in(BERLIN) {
        gas!(context.interpreter, warm_cold_cost(code_hash.is_cold));
    } else if spec_id.is_enabled_in(ISTANBUL) {
        gas!(context.interpreter, 700);
    } else {
        gas!(context.interpreter, 400);
    }
    *top = code_hash.into_u256();
}

/// Implements the EXTCODECOPY instruction.
///
/// Copies a portion of an account's code to memory.
pub fn extcodecopy<WIRE: InterpreterTypes, H: Host + ?Sized>(
    context: InstructionContext<'_, H, WIRE>,
) {
    popn!(
        [address, memory_offset, code_offset, len_u256],
        context.interpreter
    );
    let address = address.into_address();
    let Some(code) = context.host.load_account_code(address) else {
        context
            .interpreter
            .halt(InstructionResult::FatalExternalError);
        return;
    };

    let len = as_usize_or_fail!(context.interpreter, len_u256);
    gas_or_fail!(
        context.interpreter,
        gas::extcodecopy_cost(
            context.interpreter.runtime_flag.spec_id(),
            len,
            code.is_cold
        )
    );
    if len == 0 {
        return;
    }
    let memory_offset = as_usize_or_fail!(context.interpreter, memory_offset);
    let code_offset = min(as_usize_saturated!(code_offset), code.len());
    resize_memory!(context.interpreter, memory_offset, len);

    // Note: This can't panic because we resized memory to fit.
    context
        .interpreter
        .memory
        .set_data(memory_offset, code_offset, len, &code);
}

/// Implements the BLOCKHASH instruction.
///
/// Gets the hash of one of the 256 most recent complete blocks.
pub fn blockhash<WIRE: InterpreterTypes, H: Host + ?Sized>(
    context: InstructionContext<'_, H, WIRE>,
) {
    //gas!(context.interpreter, gas::BLOCKHASH);
    popn_top!([], number, context.interpreter);

    let requested_number = *number;
    let block_number = context.host.block_number();

    let Some(diff) = block_number.checked_sub(requested_number) else {
        *number = U256::ZERO;
        return;
    };

    let diff = as_u64_saturated!(diff);

    // blockhash should push zero if number is same as current block number.
    if diff == 0 {
        *number = U256::ZERO;
        return;
    }

    *number = if diff <= BLOCK_HASH_HISTORY {
        let Some(hash) = context.host.block_hash(as_u64_saturated!(requested_number)) else {
            context
                .interpreter
                .halt(InstructionResult::FatalExternalError);
            return;
        };
        U256::from_be_bytes(hash.0)
    } else {
        U256::ZERO
    }
}

/// Implements the SLOAD instruction.
///
/// Loads a word from storage.
pub fn sload<WIRE: InterpreterTypes, H: Host + ?Sized>(context: InstructionContext<'_, H, WIRE>) {
    popn_top!([], index, context.interpreter);

    let Some(value) = context
        .host
        .sload(context.interpreter.input.target_address(), *index)
    else {
        context
            .interpreter
            .halt(InstructionResult::FatalExternalError);
        return;
    };

    gas!(
        context.interpreter,
        gas::sload_cost(context.interpreter.runtime_flag.spec_id(), value.is_cold)
    );
    *index = value.data;
}

/// Implements the SSTORE instruction.
///
/// Stores a word to storage.
pub fn sstore<WIRE: InterpreterTypes, H: Host + ?Sized>(context: InstructionContext<'_, H, WIRE>) {
    require_non_staticcall!(context.interpreter);

    popn!([index, value], context.interpreter);

    let Some(state_load) =
        context
            .host
            .sstore(context.interpreter.input.target_address(), index, value)
    else {
        context
            .interpreter
            .halt(InstructionResult::FatalExternalError);
        return;
    };

    // EIP-1706 Disable SSTORE with gasleft lower than call stipend
    if context
        .interpreter
        .runtime_flag
        .spec_id()
        .is_enabled_in(ISTANBUL)
        && context.interpreter.gas.remaining() <= CALL_STIPEND
    {
        context
            .interpreter
            .halt(InstructionResult::ReentrancySentryOOG);
        return;
    }
    gas!(
        context.interpreter,
        gas::sstore_cost(
            context.interpreter.runtime_flag.spec_id(),
            &state_load.data,
            state_load.is_cold
        )
    );

    context.interpreter.gas.record_refund(gas::sstore_refund(
        context.interpreter.runtime_flag.spec_id(),
        &state_load.data,
    ));
}

/// EIP-1153: Transient storage opcodes
/// Store value to transient storage
pub fn tstore<WIRE: InterpreterTypes, H: Host + ?Sized>(context: InstructionContext<'_, H, WIRE>) {
    check!(context.interpreter, CANCUN);
    require_non_staticcall!(context.interpreter);
    //gas!(context.interpreter, gas::WARM_STORAGE_READ_COST);

    popn!([index, value], context.interpreter);

    context
        .host
        .tstore(context.interpreter.input.target_address(), index, value);
}

/// EIP-1153: Transient storage opcodes
/// Load value from transient storage
pub fn tload<WIRE: InterpreterTypes, H: Host + ?Sized>(context: InstructionContext<'_, H, WIRE>) {
    check!(context.interpreter, CANCUN);
    //gas!(context.interpreter, gas::WARM_STORAGE_READ_COST);

    popn_top!([], index, context.interpreter);

    *index = context
        .host
        .tload(context.interpreter.input.target_address(), *index);
}

/// Implements the LOG0-LOG4 instructions.
///
/// Appends log record with N topics.
pub fn log<const N: usize, H: Host + ?Sized>(
    context: InstructionContext<'_, H, impl InterpreterTypes>,
) {
    require_non_staticcall!(context.interpreter);

    popn!([offset, len], context.interpreter);
    let len = as_usize_or_fail!(context.interpreter, len);
    gas_or_fail!(context.interpreter, gas::log_cost(N as u8, len as u64));
    let data = if len == 0 {
        Bytes::new()
    } else {
        let offset = as_usize_or_fail!(context.interpreter, offset);
        resize_memory!(context.interpreter, offset, len);
        Bytes::copy_from_slice(context.interpreter.memory.slice_len(offset, len).as_ref())
    };
    if context.interpreter.stack.len() < N {
        context.interpreter.halt(InstructionResult::StackUnderflow);
        return;
    }
    let Some(topics) = context.interpreter.stack.popn::<N>() else {
        context.interpreter.halt(InstructionResult::StackUnderflow);
        return;
    };

    let log = Log {
        address: context.interpreter.input.target_address(),
        data: LogData::new(topics.into_iter().map(B256::from).collect(), data)
            .expect("LogData should have <=4 topics"),
    };

    context.host.log(log);
}

/// Implements the SELFDESTRUCT instruction.
///
/// Halt execution and register account for later deletion.
///
/// A Supra reserved address is never the beneficiary: the instruction halts with
/// [`InstructionResult::ReservedAddressTarget`] instead, in every execution mode.
pub fn selfdestruct<WIRE: InterpreterTypes, H: Host + ?Sized>(
    context: InstructionContext<'_, H, WIRE>,
) {
    require_non_staticcall!(context.interpreter);
    popn!([target], context.interpreter);
    let target = target.into_address();

    // `SELFDESTRUCT` credits its beneficiary without calling it, so no code or precompile at the
    // beneficiary sees the value arrive. Value reaches a reserved address only through a call to
    // a precompile registered there (`EthFrame::make_call_frame`), so a reserved beneficiary is
    // refused, precompile or not, and whatever the balance being moved. The check precedes
    // `Host::selfdestruct` so that a refused instruction neither loads the beneficiary nor writes
    // a journal entry. See smr-moonshot#3117.
    if is_supra_reserved(&target) {
        context
            .interpreter
            .halt(InstructionResult::ReservedAddressTarget);
        return;
    }

    let Some(res) = context
        .host
        .selfdestruct(context.interpreter.input.target_address(), target)
    else {
        context
            .interpreter
            .halt(InstructionResult::FatalExternalError);
        return;
    };

    // EIP-3529: Reduction in refunds
    if !context
        .interpreter
        .runtime_flag
        .spec_id()
        .is_enabled_in(LONDON)
        && !res.previously_destroyed
    {
        context.interpreter.gas.record_refund(gas::SELFDESTRUCT)
    }

    gas!(
        context.interpreter,
        gas::selfdestruct_cost(context.interpreter.runtime_flag.spec_id(), res)
    );

    context.interpreter.halt(InstructionResult::SelfDestruct);
}

#[cfg(test)]
mod tests {
    use crate::{
        host::DummyHost,
        instructions::instruction_table,
        interpreter::{EthInterpreter, ExtBytecode},
        InputsImpl, InstructionResult, Interpreter, InterpreterAction, SharedMemory,
    };
    use bytecode::{opcode, Bytecode};
    use primitives::{
        hardfork::SpecId,
        supra_constants::{u64_to_address, TX_HASH_ADDRESS, VM_SIGNER},
        Address, Bytes,
    };

    /// Runs `PUSH20 beneficiary; SELFDESTRUCT` against `DummyHost` and returns the result the
    /// frame ends with.
    ///
    /// `DummyHost::selfdestruct` returns `None`, which the instruction turns into
    /// `FatalExternalError`. A run that ends with any other result therefore never reached the
    /// host.
    fn selfdestruct_result(beneficiary: Address, is_static: bool) -> InstructionResult {
        let mut code = vec![opcode::PUSH20];
        code.extend_from_slice(beneficiary.as_slice());
        code.push(opcode::SELFDESTRUCT);

        let mut interpreter = Interpreter::<EthInterpreter>::new(
            SharedMemory::new(),
            ExtBytecode::new(Bytecode::new_raw(Bytes::from(code))),
            InputsImpl::default(),
            is_static,
            SpecId::PRAGUE,
            1_000_000,
        );
        let table = instruction_table::<EthInterpreter, DummyHost>();
        match interpreter.run_plain(&table, &mut DummyHost) {
            InterpreterAction::Return(result) => result.result,
            other => panic!("SELFDESTRUCT must end the frame, got: {other:?}"),
        }
    }

    /// A reserved beneficiary halts the instruction before the host is asked to self-destruct.
    #[test]
    fn selfdestruct_to_a_reserved_beneficiary_halts_before_the_host() {
        for beneficiary in [
            VM_SIGNER,
            TX_HASH_ADDRESS,
            u64_to_address(0x5355_5002),
            u64_to_address(0x5355_50FF),
        ] {
            assert_eq!(
                selfdestruct_result(beneficiary, false),
                InstructionResult::ReservedAddressTarget,
                "beneficiary {beneficiary}"
            );
        }
    }

    /// An address on either side of the reserved range reaches the host.
    #[test]
    fn selfdestruct_to_an_address_outside_the_reserved_range_reaches_the_host() {
        for beneficiary in [u64_to_address(0x5355_4FFF), u64_to_address(0x5355_5100)] {
            assert_eq!(
                selfdestruct_result(beneficiary, false),
                InstructionResult::FatalExternalError,
                "beneficiary {beneficiary}"
            );
        }
    }

    /// The static-call check precedes the reserved-beneficiary check.
    #[test]
    fn selfdestruct_in_a_static_call_reports_the_static_violation() {
        assert_eq!(
            selfdestruct_result(VM_SIGNER, true),
            InstructionResult::StateChangeDuringStaticCall
        );
    }
}
