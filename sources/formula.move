module apump_ai::formula {
    use std::error;

    const MAX_WEIGHT: u32 = 1000000;
    const PRECISION: u128 = 1_000_000_000;

    const E_WEIGHT_EXCEEDED: u64 = 1;
    const E_SELL_AMOUNT_EXCEEDED_SUPPLY: u64 = 2;
    const E_ZERO_SUPPLY: u64 = 3;
    const E_ZERO_BALANCE: u64 = 4;
    const E_ZERO_WEIGHT: u64 = 5;
    const E_OVERFLOW: u64 = 65542;

    public fun calculate_purchase_return(
        s: u128,
        b: u128,
        w: u32,
        p: u128
    ): u128 {
        assert!(s != 0, error::invalid_argument(E_ZERO_SUPPLY));
        assert!(b != 0, error::invalid_argument(E_ZERO_BALANCE));
        assert!(w != 0, error::invalid_argument(E_ZERO_WEIGHT));
        assert!(w <= MAX_WEIGHT, error::invalid_argument(E_WEIGHT_EXCEEDED));
        if (p == 0) return 0;

        if (w == MAX_WEIGHT) {
            let r0 = div_u128(p, b);
            return mul_u128(s, r0);
        };

        let pp = add_u128(p, b);
        let base = div_u128(pp, b);
        let exponent = div_u128((w as u128) * PRECISION, (MAX_WEIGHT as u128)); // w / 1000000
        let r = pow_u128(base, exponent);
        let sp = mul_u128(s, r);
        sub_u128(sp, s)
    }

    public fun calculate_sale_return(
        s: u128,
        b: u128,
        w: u32,
        k: u128
    ): u128 {
        assert!(s != 0, error::invalid_argument(E_ZERO_SUPPLY));
        assert!(b != 0, error::invalid_argument(E_ZERO_BALANCE));
        assert!(w != 0, error::invalid_argument(E_ZERO_WEIGHT));
        assert!(w <= MAX_WEIGHT, error::invalid_argument(E_WEIGHT_EXCEEDED));
        assert!(k <= s, error::invalid_argument(E_SELL_AMOUNT_EXCEEDED_SUPPLY));
        if (k == 0) return 0;
        if (k == s) return b;

        if (w == MAX_WEIGHT) {
            let r0 = div_u128(k, s);
            return mul_u128(b, r0);
        };

        let sp = sub_u128(s, k);
        let base = div_u128(sp, s);
        let exponent = div_u128((MAX_WEIGHT as u128) * PRECISION, (w as u128));
        let r = pow_u128(base, exponent);
        let bp = mul_u128(b, r);
        sub_u128(b, bp)
    }

    fun add_u128(a: u128, b: u128): u128 {
        let sum = a + b;
        assert!(sum >= a, error::invalid_argument(E_OVERFLOW));
        sum
    }

    fun sub_u128(a: u128, b: u128): u128 {
        assert!(a >= b, error::invalid_argument(0));
        a - b
    }

    fun mul_u128(a: u128, b: u128): u128 {
        let prod = a * b / PRECISION;
        assert!(prod * PRECISION / a == b, error::invalid_argument(0));
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
}