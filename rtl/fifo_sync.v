`default_nettype none
// Learning skeleton: implement numbered TODOs using sim/test_fifo_sync.py as spec.
// One clock domain, registered read, WIDTH >= 1 and DEPTH >= 2.
module fifo_sync #(
    parameter integer WIDTH = 8,
    parameter integer DEPTH = 16
)(
    input  wire clk,
    input  wire rst,
    input  wire wr_en,
    input  wire [WIDTH-1:0] wr_data,
    input  wire rd_en,
    output reg  [WIDTH-1:0] rd_data,
    output reg  rd_valid,
    output wire full,
    output wire empty,
    output reg  [$clog2(DEPTH+1)-1:0] level,
    output reg  overflow,
    output reg  underflow
);
    localparam integer PW = $clog2(DEPTH);
    localparam integer CW = $clog2(DEPTH + 1);
    localparam integer LAST_I = DEPTH - 1;
    localparam [PW-1:0] LAST_ADDR = LAST_I[PW-1:0];
    localparam [CW-1:0] CAPACITY = DEPTH[CW-1:0];

    reg [WIDTH-1:0] mem [0:DEPTH-1];
    reg [PW-1:0] wr_ptr;
    reg [PW-1:0] rd_ptr;
    wire read_accept;
    wire write_accept;

    // TODO 1: Continuous assignments for empty/full from level and CAPACITY.
    // Define read_accept and write_accept from requests and PRE-edge occupancy.
    // A simultaneous accepted read permits a write even when full.
    // Empty + both requests stores the word but does NOT bypass it to rd_data.
    assign empty = (level == {CW{1'b0}});
    assign full  = (level == CAPACITY);
    assign read_accept  = rd_en && !empty;
    assign write_accept = wr_en && (!full || read_accept);

    always @(posedge clk) begin
        if (rst) begin
            // TODO 2: Reset both pointers, level, rd_data and all three event flags.
            // Do not clear mem: zero occupancy makes old storage inaccessible.
            wr_ptr    <= {PW{1'b0}};
            rd_ptr    <= {PW{1'b0}};
            level     <= {CW{1'b0}};
            rd_data   <= {WIDTH{1'b0}};
            rd_valid  <= 1'b0;
            overflow  <= 1'b0;
            underflow <= 1'b0;
        end else begin
            // TODO 3: Set rd_valid, overflow and underflow for this edge only.
            // Each rejected request produces its own error cycle, even if the
            // same request was also rejected on the previous cycle.
            rd_valid  <= read_accept;
            overflow  <= wr_en && !write_accept;
            underflow <= rd_en && !read_accept;

            // TODO 4: On write_accept, store wr_data and advance wr_ptr.
            // Explicitly wrap at LAST_ADDR; DEPTH need not be a power of two.
            if (write_accept) begin
                mem[wr_ptr] <= wr_data;
                if (wr_ptr == LAST_ADDR)
                    wr_ptr <= {PW{1'b0}};
                else
                    wr_ptr <= wr_ptr + 1'b1;
            end

            // TODO 5: On read_accept, register the OLD head into rd_data and
            // advance rd_ptr with explicit wrapping. Otherwise hold rd_data.
            // Nonblocking assignments preserve the old word on full read+write.
            if (read_accept) begin
                rd_data <= mem[rd_ptr];
                if (rd_ptr == LAST_ADDR)
                    rd_ptr <= {PW{1'b0}};
                else
                    rd_ptr <= rd_ptr + 1'b1;
            end

            // TODO 6: Increment level for write-only, decrement for read-only,
            // hold for both/neither. Base this on ACCEPTED operations.
            case ({write_accept, read_accept})
                2'b10:  level <= level + 1'b1;
                2'b01:  level <= level - 1'b1;
                default: level <= level;
            endcase
        end
    end
endmodule
`default_nettype wire
