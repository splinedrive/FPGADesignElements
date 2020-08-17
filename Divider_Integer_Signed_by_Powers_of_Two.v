
//# Signed Integer Divider by Powers of Two (Truncating Division)

// While a left shift by N is always equivalent to a multiplication by
// 2<sup>N</sup> for both signed and unsigned binary integers, an arithmetic
// shift right by N is only a truncating division by 2<sup>N</sup> for
// *positive* binary integers. For negative integers, the result is a so-called
// modulus division, and the quotient ends up off by one in magnitude, and
// must be corrected by adding +1, *but only if an odd number results as part
// of the intermediate division steps*.

// The implementation is based on the PowerPC method, as described in <a
// href="./reading.html#Warren2013">Hacker's Delight</a>, Section 10-1, *"Signed
// Division by a Known Power of Two"*: We perform the right shift and take
// note if any 1-bits are shifted out. If so, add one to the shifted value.

// Since we divide only by powers of two, a division by zero cannot happen.
// (i.e.: there exists no N where 2<sup>N</sup> = 0) Also, we only allow
// positive exponents. A negative exponent would imply a multiplication, and
// that can be done directly with a left shift and not all this complication.

// Note that shifting by more than the WORD_WIDTH, with an exponent of value
// greater than WORD_WIDTH, will give a nonsense result for negative numbers
// as we only have WORD_WIDTH sign bits to shift in at most. 

`default_nettype none

module Divider_Integer_Signed_by_Powers_of_Two
#(
    parameter WORD_WIDTH = 0
)
(
    input  wire signed [WORD_WIDTH-1:0] numerator,
    input  wire        [WORD_WIDTH-1:0] exponent_of_two,

    output wire signed [WORD_WIDTH-1:0] quotient,
    output wire signed [WORD_WIDTH-1:0] remainder
);

    localparam WORD_ZERO = {WORD_WIDTH{1'b0}};
    localparam WORD_ONES = {WORD_WIDTH{1'b1}};
    localparam ONE       = {{WORD_WIDTH-1{1'b0}},1'b1};

// We depend on automatic width extension of the WORD_WIDTH integer here, as
// doing it using a loop in an initial block is worse for linting and CAD
// warnings.  I normally don't allow automatic width extension, but in this
// case it will always work, as the register will always store up to
// 2<sup>N</sup>-1 for a WORD_WIDTH of N, and N is always unsigned.  This
// width extension is necessary to match port widths later on. We do have to
// silence the linter, though.

    // verilator lint_off WIDTH
    reg [WORD_WIDTH-1:0] WORD_WIDTH_LONG = WORD_WIDTH;
    // verilator lint_on  WIDTH

    localparam POSITIVE  = 1'b0;
    localparam NEGATIVE  = 1'b1;

// Prepare for a positive or negative numerator.
// The remainder will also make use of the sign extension.

    reg                  numerator_sign = 1'b0;
    reg [WORD_WIDTH-1:0] sign_extension = WORD_ZERO;

    always @(*) begin
        numerator_sign = numerator[WORD_WIDTH-1];
        sign_extension = {WORD_WIDTH{numerator_sign}};
    end

// Do the initial, uncorrected division.
// The remainder is "short" because all its significant bits are at the left.
// We will shift them, with sign extension, back to the right later.

    wire [WORD_WIDTH-1:0] uncorrected_quotient;
    wire [WORD_WIDTH-1:0] short_remainder;

    Bit_Shifter
    #(
        .WORD_WIDTH         (WORD_WIDTH)
    )
    uncorrected_division
    (
        .word_in_left       (sign_extension),
        .word_in            (numerator),
        .word_in_right      (WORD_ZERO),

        .shift_amount       (exponent_of_two),
        .shift_direction    (1'b1),             // 0/1 -> left/right

        // verilator lint_off PINCONNECTEMPTY
        .word_out_left      (),
        // verilator lint_on  PINCONNECTEMPTY
        .word_out           (uncorrected_quotient),
        .word_out_right     (short_remainder)
    );

// We need to know if at any point during the shift, a 1-bit was shifted into
// the remainder, indicating an odd-valued intermediate result, and thus an
// off-by-one error in the quotient. A simple OR-reduction works because we
// primed that part of the shift with zeros.

    reg odd_intermediate_result = 1'b0;

    always @(*) begin
        odd_intermediate_result = (short_remainder != WORD_ZERO);
    end

// Now, if the numerator was negative, and there was an odd-valued
// intermediate result, let's add +1 to the uncorrected_quotient to bring it
// back to the result a truncating division would give us.

    reg correction = 1'b0;

    always @(*) begin
        correction = (numerator_sign == NEGATIVE) && (odd_intermediate_result == 1'b1);
    end

    Adder_Subtractor_Binary
    #(
        .WORD_WIDTH     (WORD_WIDTH)
    )
    quotient_correction
    (
        .add_sub        (1'b0),    // 0/1 -> A+B/A-B
        .carry_in       (correction),
        .A_in           (uncorrected_quotient),
        .B_in           (WORD_ZERO),
        .sum_out        (quotient),
        // verilator lint_off PINCONNECTEMPTY
        .carry_out      ()
        // verilator lint_on  PINCONNECTEMPTY
    );

// To shift the short remainder back to the right, we need to shift by the
// remainder of the distance to the right, which is WORD_WIDTH
// - exponent_of_two.

    wire [WORD_WIDTH-1:0] remainder_shift_amount;

    Adder_Subtractor_Binary
    #(
        .WORD_WIDTH     (WORD_WIDTH)
    )
    remainder_alignment
    (
        .add_sub        (1'b1),    // 0/1 -> A+B/A-B
        .carry_in       (1'b0),
        .A_in           (WORD_WIDTH_LONG),
        .B_in           (exponent_of_two),
        .sum_out        (remainder_shift_amount),
        // verilator lint_off PINCONNECTEMPTY
        .carry_out      ()
        // verilator lint_on  PINCONNECTEMPTY
    );

// Finally, let's shift the remainder significant bits back to the right, with
// the same sign extension as the quotient if the remainder was not zero.

    Bit_Shifter
    #(
        .WORD_WIDTH         (WORD_WIDTH)
    )
    remainder_extension
    (
        .word_in_left       (sign_extension),
        .word_in            (short_remainder),
        .word_in_right      (WORD_ZERO),

        .shift_amount       (remainder_shift_amount),
        .shift_direction    (1'b1),             // 0/1 -> left/right

        // verilator lint_off PINCONNECTEMPTY
        .word_out_left      (),
        .word_out           (remainder),
        .word_out_right     ()
        // verilator lint_on  PINCONNECTEMPTY
    );

endmodule

