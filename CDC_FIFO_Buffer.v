
//# CDC (Clock Domain Crossing) FIFO Buffer

// Decouples two sides, *each in their own asynchronous clock domain*, of
// a ready/valid handshake to allow back-to-back transfers without
// a combinational path between input and output, thus pipelining the path to
// improve concurrency and/or timing. *Any FIFO depth is allowed, not only
// powers-of-2.* The minimum input-to-output latency is 7 cycles when both
// clocks are plesiochronous.

// Since a FIFO buffer stores variable amounts of data, it will smooth out
// irregularities in the transfer rates of the input and output interfaces,
// and when used in pipeline loops, can store enough data to prevent
// artificial deadlocks (re: [Kahn Process
// Networks](https://en.wikipedia.org/wiki/Kahn_process_networks#Boundedness_of_channels)
// with bounded channels).

// *This module is directly derived from Clifford E. Cummings' <a
// href="http://www.sunburst-design.com/papers/CummingsSNUG2002SJ_FIFO1.pdf">Simulation
// and Synthesis Techniques for Asynchronous FIFO Design</a>, SNUG 2002, San
// Jose.*

// If you do not need to cross clock domains, use the simpler, lower-latency
// [Pipeline FIFO Buffer](./Pipeline_FIFO_Buffer.html).

//## Asynchronous Clocks

// This FIFO supports having the input and output interfaces each on their own
// mutually asynchronous clock (without knowledge or restriction on their
// relative clock frequencies or phase).  Using a FIFO for data tranfer
// between asynchronous clock domains allows multiple transfers to overlap
// with the CDC synchronization overhead. Once the CDC synchronization is
// done, all the previously written data in one clock domain can be freely
// read out in the other clock domain without further overhead.

//## Resets

// Since the input and output interfaces are asynchronous to eachother, they
// each have their own locally-synchronous `clear` reset signal. However, it
// makes no sense to reset one interface only, as that would corrupt the
// read/write addresses and duplicate or lose data. *Both interfaces must be reset
// together.* Pick one interface reset as the primary reset, then synchronize
// it into the clock domain of the other interface using a [CDC
// Synchronizer](./CDC_Synchronizer.html).

// The synchronized reset will release after the primary reset, but that will
// cause no problems: if the input interface comes out of reset first, it can
// begin storing data until the FIFO is full. If the output interface comes
// out of reset first, it will remain idle as the FIFO will remain empty until
// the input interface stores a data item.

//## Parameters, Ports, and Initializations

`default_nettype none

module CDC_FIFO_Buffer
#(
    parameter WORD_WIDTH        = 33,
    parameter DEPTH             = 23,
    parameter RAMSTYLE          = "block",
    parameter CDC_EXTRA_STAGES  = 0
)
(
    input   wire                        input_clock,
    input   wire                        input_clear,
    input   wire                        input_valid,
    output  reg                         input_ready,
    input   wire    [WORD_WIDTH-1:0]    input_data,

    input   wire                        output_clock,
    input   wire                        output_clear,
    output  wire                        output_valid,
    input   wire                        output_ready,
    output  wire    [WORD_WIDTH-1:0]    output_data
);

    initial begin
        input_ready = 1'b1; // Empty at start, so accept data
    end

//## Constants

// From the FIFO `DEPTH`, we derive the bit width of the buffer addresses and
// construct the constants we work with.

    `include "clog2_function.vh"

    localparam WORD_ZERO    = {WORD_WIDTH{1'b0}};

    localparam ADDR_WIDTH   = clog2(DEPTH);
    localparam ADDR_ONE     = {{ADDR_WIDTH-1{1'b0}},1'b1};
    localparam ADDR_ZERO    = {ADDR_WIDTH{1'b0}};
    localparam ADDR_LAST    = DEPTH-1;

//## Data Path

// The buffer itself is a *synchronous* dual-port memory with dual clocks: one
// write port to insert data, and one read port to concurrently remove data,
// each in their own clock domain. Typically this memory will be a dedicated
// Block RAM, but can also be built from LUT RAM if the width and depth are
// small, or even plain registers for very small cases. Set the `RAMSTYLE`
// parameter as required.

// **NOTE**: There will *NEVER* be a concurrent read and write to the same
// address, so write-forwarding logic is not necessary, nor possible since
// `read_clock` and `write_clock` are asynchronous.  Guide your CAD tool as
// necessary to tell it there will never be read/write address collisions, so
// you can obtain the highest possible operating frequency. 

// We initialize the read/write enables to zero, signifying an idle system.

    reg                     buffer_wren = 1'b0;
    wire [ADDR_WIDTH-1:0]   buffer_write_addr;

    reg                     buffer_rden = 1'b0;
    wire [ADDR_WIDTH-1:0]   buffer_read_addr;

    RAM_Simple_Dual_Port_Dual_Clock
    #(
        .WORD_WIDTH     (WORD_WIDTH),
        .ADDR_WIDTH     (ADDR_WIDTH),
        .DEPTH          (DEPTH),
        .RAMSTYLE       (RAMSTYLE),
        .USE_INIT_FILE  (0),
        .INIT_FILE      (),
        .INIT_VALUE     (WORD_ZERO)
    )
    buffer
    (
        .write_clock    (input_clock),
        .wren           (buffer_wren),
        .write_addr     (buffer_write_addr),
        .write_data     (input_data),

        .read_clock     (output_clock),
        .rden           (buffer_rden),
        .read_addr      (buffer_read_addr),
        .read_data      (output_data)
    );

//### Read/Write Address Counters

// The buffer read and write addresses are stored in counters, running in
// separate clock domains, which both start at (and `clear` to) `ADDR_ZERO`.
// Each counter can only increment by `ADDR_ONE` at each read or write, and
// will wrap around to `ADDR_ZERO` if incremented past a value of `DEPTH-1`,
// labelled as `ADDR_LAST` (`load` overrides `run`). *The depth can be any
// positive number, not only a power-of-2.*

    reg increment_buffer_write_addr = 1'b0;
    reg load_buffer_write_addr      = 1'b0;

    Counter_Binary
    #(
        .WORD_WIDTH     (ADDR_WIDTH),
        .INCREMENT      (ADDR_ONE),
        .INITIAL_COUNT  (ADDR_ZERO)
    )
    write_address
    (
        .clock          (input_clock),
        .clear          (input_clear),
        .up_down        (1'b0), // 0/1 --> up/down
        .run            (increment_buffer_write_addr),
        .load           (load_buffer_write_addr),
        .load_count     (ADDR_ZERO),
        .carry_in       (1'b0),
        // verilator lint_off PINCONNECTEMPTY
        .carry_out      (),
        .carries        (),
        .overflow       (),
        // verilator lint_on  PINCONNECTEMPTY
        .count          (buffer_write_addr)
    );

    reg increment_buffer_read_addr = 1'b0;
    reg load_buffer_read_addr      = 1'b0;

    Counter_Binary
    #(
        .WORD_WIDTH     (ADDR_WIDTH),
        .INCREMENT      (ADDR_ONE),
        .INITIAL_COUNT  (ADDR_ZERO)
    )
    read_address
    (
        .clock          (output_clock),
        .clear          (output_clear),
        .up_down        (1'b0), // 0/1 --> up/down
        .run            (increment_buffer_read_addr),
        .load           (load_buffer_read_addr),
        .load_count     (ADDR_ZERO),
        .carry_in       (1'b0),
        // verilator lint_off PINCONNECTEMPTY
        .carry_out      (),
        .carries        (),
        .overflow       (),
        // verilator lint_on  PINCONNECTEMPTY
        .count          (buffer_read_addr)
    );

//### Wrap-Around Bits

// To distinguish between the empty and full cases, which both identically
// show as equal read and write buffer addresses, we keep track of each time
// an address wraps around to zero by toggling a bit.  *The addresses never
// pass eachother.* 

// If the write address runs ahead of the read address enough to wrap-around
// and reach the read address from behind, the buffer is full and all writes
// to the buffer halt until after a read happens. We detect this because the
// write address will have wrapped-around one more time than the read address,
// so their wrap-around bits will be different.

// Conversely, if the read address catches up to the write address from
// behind, the buffer is empty and all reads halt until after a write happens.
// In this case, the wrap-around bits are identical.

    reg  toggle_buffer_write_addr_wrap_around = 1'b0;
    wire buffer_write_addr_wrap_around;

    Register_Toggle
    #(
        .WORD_WIDTH     (1),
        .RESET_VALUE    (1'b0)
    )
    write_wrap_around_bit
    (
        .clock          (input_clock),
        .clock_enable   (1'b1),
        .clear          (input_clear),
        .toggle         (toggle_buffer_write_addr_wrap_around),
        .data_in        (buffer_write_addr_wrap_around),
        .data_out       (buffer_write_addr_wrap_around)
    );

    reg  toggle_buffer_read_addr_wrap_around = 1'b0;
    wire buffer_read_addr_wrap_around;

    Register_Toggle
    #(
        .WORD_WIDTH     (1),
        .RESET_VALUE    (1'b0)
    )
    read_wrap_around_bit
    (
        .clock          (output_clock),
        .clock_enable   (1'b1),
        .clear          (output_clear),
        .toggle         (toggle_buffer_read_addr_wrap_around),
        .data_in        (buffer_read_addr_wrap_around),
        .data_out       (buffer_read_addr_wrap_around)
    );

//### Read/Write Address CDC Transfer

// We need to compare the read and write addresses, along with their
// associated wrap-around bits, to detect if the buffer is holding any items.
// Therefore, we need to transfer the read address into the `output_clock`
// domain, and the write address into the `input_clock` domain. We do this
// with two CDC Word Synchronizers.

// A read/write address is always valid, so we tie `sending_valid` high and
// ignore `sending_ready`. Then, we loop `receiving_valid` into
// `receiving_ready` so we start a new CDC word transfer as soon as the
// current CDC word transfer completes. This configuration samples the address
// continuously, as fast as the CDC word transfer happens. The synchronized
// address at `receiving_data` remains steady between CDC word transfers.

// It takes a few cycles to do the CDC word transfer, so when comparing the
// local read or write address with the synchronized counterpart from the
// other clock domain, we are comparing to a slightly stale version, lagging
// behind the actual value. However, since the addresses never pass eachother,
// this does not cause any corruption. The synchronized value eventually
// catches up, and the actual buffer condition is updated. *At worst, this lag
// means having to specify a somewhat deeper FIFO to achieve the expected peak
// capacity, depending on input/output rates.* However, not being restricted
// to powers-of-two FIFO depths minimizes this overhead.

    wire [ADDR_WIDTH-1:0]   buffer_write_addr_synced;
    wire                    buffer_write_addr_wrap_around_synced;
    wire                    buffer_write_addr_synced_valid;

    CDC_Word_Synchronizer
    #(
        .WORD_WIDTH             (ADDR_WIDTH + 1),
        .EXTRA_CDC_DEPTH        (CDC_EXTRA_STAGES),
        .OUTPUT_BUFFER_TYPE     ("HALF"), // "HALF", "SKID", "FIFO"
        .FIFO_BUFFER_DEPTH      (), // Only for "FIFO"
        .FIFO_BUFFER_RAMSTYLE   ()  // Only for "FIFO"
    )
    write_to_read
    (
        .sending_clock          (input_clock),
        .sending_clear          (input_clear),
        .sending_data           ({buffer_write_addr_wrap_around, buffer_write_addr}),
        .sending_valid          (1'b1),
        // verilator lint_off PINCONNECTEMPTY
        .sending_ready          (),
        // verilator lint_on  PINCONNECTEMPTY

        .receiving_clock        (output_clock),
        .receiving_clear        (output_clear),
        .receiving_data         ({buffer_write_addr_wrap_around_synced, buffer_write_addr_synced}),
        .receiving_valid        (buffer_write_addr_synced_valid),
        .receiving_ready        (buffer_write_addr_synced_valid)
    );

    wire [ADDR_WIDTH-1:0]   buffer_read_addr_synced;
    wire                    buffer_read_addr_wrap_around_synced;
    wire                    buffer_read_addr_synced_valid;

    CDC_Word_Synchronizer
    #(
        .WORD_WIDTH             (ADDR_WIDTH + 1),
        .EXTRA_CDC_DEPTH        (CDC_EXTRA_STAGES),
        .OUTPUT_BUFFER_TYPE     ("HALF"), // "HALF", "SKID", "FIFO"
        .FIFO_BUFFER_DEPTH      (), // Only for "FIFO"
        .FIFO_BUFFER_RAMSTYLE   ()  // Only for "FIFO"
    )
    read_to_write
    (
        .sending_clock          (output_clock),
        .sending_clear          (output_clear),
        .sending_data           ({buffer_read_addr_wrap_around, buffer_read_addr}),
        .sending_valid          (1'b1),
        // verilator lint_off PINCONNECTEMPTY
        .sending_ready          (),
        // verilator lint_on  PINCONNECTEMPTY

        .receiving_clock        (input_clock),
        .receiving_clear        (input_clear),
        .receiving_data         ({buffer_read_addr_wrap_around_synced, buffer_read_addr_synced}),
        .receiving_valid        (buffer_read_addr_synced_valid),
        .receiving_ready        (buffer_read_addr_synced_valid)
    );


//## Control Path

//### Buffer States

// We describe the state of the buffer itself as the number of items currently
// stored in the buffer, as indicated by the read and write addresses and
// their wrap-around bits. We only care about the extremes: if the buffer
// holds no items, or if it holds its maximum number of items, as explained
// above.

    reg stored_items_zero = 1'b0;
    reg stored_items_max  = 1'b0;

    always @(*) begin
        stored_items_zero = (buffer_read_addr        == buffer_write_addr_synced) && (buffer_read_addr_wrap_around        == buffer_write_addr_wrap_around_synced);
        stored_items_max  = (buffer_read_addr_synced == buffer_write_addr)        && (buffer_read_addr_wrap_around_synced != buffer_write_addr_wrap_around);
    end

//### Input Interface (Insert)

// The input interface is simple: if the buffer isn't at its maximum capacity,
// signal the input is ready, and when an input handshake completes, write the
// data directly into the buffer and increment the write address, wrapping
// around as necessary.

    reg insert = 1'b0;

    always @(*) begin
        input_ready                             = (stored_items_max == 1'b0);
        insert                                  = (input_valid      == 1'b1) && (input_ready  == 1'b1);

        buffer_wren                             = (insert == 1'b1);
        increment_buffer_write_addr             = (insert == 1'b1);
        load_buffer_write_addr                  = (increment_buffer_write_addr == 1'b1) && (buffer_write_addr == ADDR_LAST [ADDR_WIDTH-1:0]);
        toggle_buffer_write_addr_wrap_around    = (load_buffer_write_addr      == 1'b1);
    end

//### Output Interface (Remove)

// The output interface is not so simple because the output is registered, and
// so holds data independently of the buffer. We signal the output holds valid
// data whenever we can remove an item from the buffer and load it into the
// output register. We meet this condition if an output handshake completes,
// or if the buffer holds an item but the output register is not holding any
// valid data.  Also, we do not increment/wrap the read address if the
// previous item removed from the buffer and loaded into the output register
// was the last one.

    reg remove                  = 1'b0;
    reg output_leaving_idle     = 1'b0;
    reg load_output_register    = 1'b0;

    always @(*) begin
        remove                              = (output_valid == 1'b1) && (output_ready        == 1'b1);
        output_leaving_idle                 = (output_valid == 1'b0) && (stored_items_zero   == 1'b0);
        load_output_register                = (remove       == 1'b1) || (output_leaving_idle == 1'b1);

        buffer_rden                         = (load_output_register == 1'b1) && (stored_items_zero == 1'b0);
        increment_buffer_read_addr          = (load_output_register == 1'b1) && (stored_items_zero == 1'b0);
        load_buffer_read_addr               = (increment_buffer_read_addr == 1'b1) && (buffer_read_addr == ADDR_LAST [ADDR_WIDTH-1:0]);
        toggle_buffer_read_addr_wrap_around = (load_buffer_read_addr      == 1'b1);
    end

// Finally, `output_valid` must be registered to match the latency of the
// `buffer` output register.

    Register
    #(
        .WORD_WIDTH     (1),
        .RESET_VALUE    (1'b0)
    )
    output_data_valid
    (
        .clock          (output_clock),
        .clock_enable   (load_output_register == 1'b1),
        .clear          (output_clear),
        .data_in        (stored_items_zero == 1'b0),
        .data_out       (output_valid)
    );

endmodule

