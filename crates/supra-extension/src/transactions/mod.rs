//! Set of transactions introduced as part of the supra extension
pub mod automated_transaction;
pub mod automation_record;
pub mod block_metadata;

/// The effective tip per gas of a fixed-price system transaction charged `price` at `base_fee`:
/// the part of the price above the base fee, or zero when the base fee is at or above the price.
///
/// It is always `Some`. alloy's default `Transaction::effective_tip_per_gas` returns `None` once
/// the base fee exceeds the price, which describes a transaction refused at that base fee. A Supra
/// system transaction (an automated transaction, an automation registry record, block-metadata)
/// is not refused for its price: it runs and is charged its fixed price at any base fee, zero for
/// the gasless ones.
#[inline]
pub fn fixed_price_effective_tip(price: u128, base_fee: u64) -> Option<u128> {
    Some(price.saturating_sub(u128::from(base_fee)))
}

#[cfg(test)]
mod tests {
    use super::fixed_price_effective_tip;

    #[test]
    fn fixed_price_effective_tip_is_price_above_base_fee_floored_at_zero() {
        assert_eq!(fixed_price_effective_tip(5_000, 0), Some(5_000));
        assert_eq!(fixed_price_effective_tip(5_000, 100), Some(4_900));
        assert_eq!(fixed_price_effective_tip(5_000, 5_000), Some(0));
        assert_eq!(fixed_price_effective_tip(5_000, 9_999), Some(0));
        assert_eq!(fixed_price_effective_tip(0, u64::MAX), Some(0));
        assert_eq!(fixed_price_effective_tip(u128::MAX, 0), Some(u128::MAX));
    }
}
