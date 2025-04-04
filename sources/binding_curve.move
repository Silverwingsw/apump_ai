module apump_ai::bonding_curve {
    use std::error;
    use aptos_framework::event;
    use apump_ai::formula::{calculate_sale_return, calculate_purchase_return};

    const PRECISION: u128 = 1_000_000_000_000_000_000;
    const MAX_WEIGHT: u32 = 1000000;
    const SLOPE_SCALE: u128 = 10000;
    const E_ZERO_SUPPLY: u64 = 3;
    const E_ZERO_BALANCE: u64 = 4;
    const E_ZERO_WEIGHT: u64 = 5;
    const E_WEIGHT_EXCEEDED: u64 = 1;

    struct Curve has key {
        slope: u64,
        reserve_ratio: u32,
    }

    #[event]
    struct CurveEvent has store, key, drop {
        slope: u64,
        reserve_ratio: u32,
    }

    fun init_module(account: &signer) {
        move_to(account, Curve {
            slope: 1000000,
            reserve_ratio: 50000
        });
        event::emit(CurveEvent {
            slope: 1000000,
            reserve_ratio: 50000
        });
    }

    fun add_u128(a: u128, b: u128): u128 {
        let sum = a + b;
        assert!(sum >= a, error::invalid_state(0));
        sum
    }

    fun sub_u128(a: u128, b: u128): u128 {
        assert!(a >= b, error::invalid_argument(0));
        a - b
    }

    fun mul_u128(a: u128, b: u128): u128 {
        let prod = a * b / PRECISION;
        assert!(prod * PRECISION / a == b, error::invalid_state(0));
        prod
    }

    fun div_u128(a: u128, b: u128): u128 {
        assert!(b != 0, error::invalid_argument(0));
        a * PRECISION / b
    }

    fun pow_u128(base: u128, exponent: u128): u128 {
        if (exponent == PRECISION) return base;
        if (exponent == 0) return PRECISION;
        let result = PRECISION;
        let b = base;
        let e = exponent / PRECISION;
        while (e > 0) {
            if (e % 2 == 1) {
                result = mul_u128(result, b);
            };
            b = mul_u128(b, b);
            e /= 2;
        };
        result
    }

    public fun compute_price_for_minting(b: u128, s: u128, k: u128): u128 acquires Curve {
        let curve = borrow_global<Curve>(@apump_ai);
        let sw = s;
        let bw = b;
        let kw = k;
        if (s == 0) {
            let wi = div_u128((MAX_WEIGHT as u128) * PRECISION, (curve.reserve_ratio as u128));
            let r = pow_u128(kw, wi);
            let m = div_u128((curve.slope as u128), SLOPE_SCALE);
            let pw0 = div_u128(mul_u128(r, m), wi);
            return pw0
        };
        let ppw = calculate_sale_return(add_u128(sw, kw), bw, curve.reserve_ratio, kw);
        let pw = div_u128(mul_u128(bw, ppw), sub_u128(bw, ppw));
        pw
    }

    public fun compute_minting_amount_from_price(b: u128, s: u128, p: u128): u128 acquires Curve {
        let curve = borrow_global<Curve>(@apump_ai);
        let sw = s;
        let bw = b;
        let pw = p;
        if (s == 0) {
            let ww = div_u128((curve.reserve_ratio as u128) * PRECISION, (MAX_WEIGHT as u128));
            let mw = div_u128((curve.slope as u128), SLOPE_SCALE);
            let base = div_u128(div_u128(pw, ww), mw);
            let kw0 = pow_u128(base, ww);
            return kw0
        };
        calculate_purchase_return(sw, bw, curve.reserve_ratio, pw)
    }

    public fun compute_refund_for_burning(b: u128, s: u128, k: u128): u128 acquires Curve {
        let curve = borrow_global<Curve>(@apump_ai);
        if (s == k) return b;
        calculate_sale_return(s, b, curve.reserve_ratio, k)
    }

    public fun compute_burning_amount_from_refund(b: u128, s: u128, p: u128): u128 acquires Curve {
        let curve = borrow_global<Curve>(@apump_ai);
        if (b == p) return s;
        let bw = b;
        let sw = s;
        let pw = p;
        let k0w = calculate_purchase_return(sw, sub_u128(bw, pw), curve.reserve_ratio, pw);
        div_u128(mul_u128(k0w, sw), add_u128(k0w, sw))
    }
}