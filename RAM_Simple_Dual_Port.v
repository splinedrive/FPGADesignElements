
//# Simple Dual-Ported RAM

// Defines a memory, of various implementation, with one write port and one
// read port (1W1R), separately addressed, with a common clock.  Common data
// width on both ports. *This is usually the fastest BRAM configuration when
// used with write-forwarding logic.*
// There is no synchronous clear on the output: In Quartus at least, any
// register driving it cannot be retimed, and it may not be as portable.
// Instead, use separate logic (e.g.: an [Annuller](./Annuller.html)) to
// zero-out the output down the line.

//## Write Forwarding

// The READ_NEW_DATA parameter control the behaviour of simultaneous reads and
// writes to the same address. This is the most important parameter when
// considering what kind of memory block the CAD tool will infer.

// * `READ_NEW_DATA = 0` describes a memory which returns the OLD value (in the
// memory) on coincident read and write (no write-forwarding).  This is
// well-suited for LUT-based memory, such as MLABs.
// * `READ_NEW_DATA = 1` (or any non-zero value) describes a memory which
// returns NEW data (from the write) on coincident read and write, usually by
// inferring some surrounding write-forwarding logic.  Good for dedicated
// Block RAMs, such as M10K.

// The inferred write-forwarding logic also allows the RAM to operate at
// higher frequency, since a read corrupted by a simultaneous write to the
// same address will be discarded and replaced by the write value at the
// output mux of the forwarding logic. Otherwise, the RAM must internally
// perform the write on one edge of the clock, and the read on the other,
// which requires a longer cycle time.

//### Quartus

// For Quartus, if you do not want write-forwarding, but still get the higher
// speed at the price of indeterminate behaviour on coincident read/writes,
// use "no_rw_check" as part of the RAMSTYLE (e.g.: "M10K, no_rw_check").
// Depending on the FPGA hardware, this may also help when returning OLD data.
// If that fails, add this setting to your Quartus project:
// `set_global_assignment -name ADD_PASS_THROUGH_LOGIC_TO_INFERRED_RAMS OFF`
// to disable creation of write-forwarding logic, as Quartus ignores the
// "no_rw_check" RAMSTYLE for M10K BRAMs.

//### Vivado

// Vivado uses a different mechanism to control write-forwarding: set
// RW_ADDR_COLLISION to "yes" to force the inference of write forwarding
// logic, or "no" to prevent it. Otherwise, set it to "auto".

`default_nettype none

module RAM_Simple_Dual_Port 
#(
    parameter                       WORD_WIDTH          = 0,
    parameter                       ADDR_WIDTH          = 0,
    parameter                       DEPTH               = 0,
    // Used as attributes, not values
    // verilator lint_off UNUSED
    parameter                       RAMSTYLE            = "",
    parameter                       RW_ADDR_COLLISION   = "",
    // verilator lint_on  UNUSED
    parameter                       READ_NEW_DATA       = 0,
    parameter                       USE_INIT_FILE       = 0,
    parameter                       INIT_FILE           = "",
    parameter   [WORD_WIDTH-1:0]    INIT_VALUE          = 0
)
(
    input  wire                         clock,
    input  wire                         wren,
    input  wire     [ADDR_WIDTH-1:0]    write_addr,
    input  wire     [WORD_WIDTH-1:0]    write_data,
    input  wire                         rden,
    input  wire     [ADDR_WIDTH-1:0]    read_addr, 
    output reg      [WORD_WIDTH-1:0]    read_data
);

    initial begin
        read_data = {WORD_WIDTH{1'b0}};
    end

// Set the ram style to control implementation.
// See your CAD tool documentation for available options.

    (* ramstyle             = RAMSTYLE *)           // Quartus
    (* ram_style            = RAMSTYLE *)           // Vivado
    (* rw_addr_collision    = RW_ADDR_COLLISION *)  // Vivado

// This is the RAM array proper. Not how we access or implement it.

    reg [WORD_WIDTH-1:0] ram [DEPTH-1:0];

// The only difference selected by READ_NEW_DATA is the use of
// blocking/non-blocking assignments.  Blocking assignments make the write
// happen logically before the read, as ordered here, and thus describe
// write-forwarding behaviour where the read takes data from the write port.
// Non-blocking assignments make read and write take effect simultaneously at
// the end of the always block, so the read takes its data from the memory.

// **UPDATE:** Since I originally wrote this code, over 10 years ago, I have
// learnt that using blocking assignments inside a clocked always block may
// cause simulation race conditions, depending on the order of evaluation of
// the always blocks (see IEEE Standard 1364-2001, Section 5, "Scheduling
// Semantics"). However, I have never seen such race conditions happen,
// possibly because of how this and other code was written (e.g.: it's in its
// own module, which affects event scheduling). I also could not find
// a simpler and cleaner way to express "write-before-read" behaviour while
// leaving the CAD tool free to infer RAM as it could. Finally, FPGA Block
// RAMs, and their CAD tools, have since changed and may no longer infer
// memory in the same way or have exactly the same supported behaviours in
// hardware.  This module should be sufficient for most purposes, but check
// your synthesis results! 

    generate
        // Returns OLD data
        if (READ_NEW_DATA == 0) begin
            always @(posedge clock) begin
                if(wren == 1'b1) begin
                    ram[write_addr] <= write_data;
                end
                if(rden == 1'b1) begin
                    read_data <= ram[read_addr];
                end
            end
        end
        // Returns NEW data
        // This isn't proper, but that's what the CAD tool expects for inference.
        // verilator lint_off BLKSEQ
        else begin
            always @(posedge clock) begin
                if(wren == 1'b1) begin
                    ram[write_addr] = write_data;
                end
                if(rden == 1'b1) begin
                    read_data = ram[read_addr];
                end
            end
        end
        // verilator lint_on BLKSEQ
    endgenerate

// If you are not using an init file, the following code will set all memory
// locations to INIT_VALUE. The CAD tool should generate a memory
// initialization file from that.  This is useful to cleanly implement small
// collections of registers (e.g.: via RAMSTYLE = "logic" on Quartus), without
// having to deal with an init file.  Your CAD tool may complain about too
// many for-loop iterations if your memory is very deep. Adjust the tool
// settings to allow more loop iterations.

// At a minimum, the initialization file format is one value per line, one for
// each memory word from 0 to DEPTH-1, in bare hexadecimal (e.g.: 0012 to init
// a 16-bit memory word with 16'h12). Note that if your WORD_WIDTH isn't
// a multiple of 4, the CAD tool may complain about the width mismatch.
// You can base yourself on this Python [memory initialization file
// generator](./RAM_generate_empty_init_file.py).

    generate
        if (USE_INIT_FILE == 0) begin
            integer i;
            initial begin
                for (i = 0; i < DEPTH; i = i + 1) begin
                    ram[i] = INIT_VALUE;
                end
            end
        end
        else begin
            initial begin
                $readmemh(INIT_FILE, ram);
            end
        end
    endgenerate

endmodule

