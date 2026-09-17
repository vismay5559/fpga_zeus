`default_nettype none
module uart_tx #(
    parameter integer CLKS_PER_BIT = 33
)(
    input  wire       clk,
    input  wire       rst,
    input  wire [7:0] data,
    input  wire       valid,
    output wire       ready,
    output reg        tx
);
    localparam integer CW = $clog2(CLKS_PER_BIT);
    localparam [CW-1:0] LAST_CNT = CLKS_PER_BIT[CW-1:0] - 1'b1;  // CW bits wide, like clk_cnt

    reg          busy;      // 1 while a frame is on the line
    reg [CW-1:0] clk_cnt;   // counts 0 .. CLKS_PER_BIT-1 inside one bit
    reg [3:0]    bit_idx;   // which of the 10 bits we are on (0 = start)
    reg [9:0]    shreg;     // {stop, data[7:0], start}

    assign ready = ~busy;

    always @(posedge clk) begin
        if (rst) begin
            busy <= 1'b0;
            tx   <= 1'b1;
            clk_cnt <= {CW{1'b0}};
            bit_idx <= 4'd0;
            shreg   <= 10'h3FF;
        end else if (!busy) begin
            // IDLE: accept a byte on valid (ready is high here)
            if (valid) begin
                shreg   <= {1'b1, data, 1'b0};
                tx      <= 1'b0;              // start bit goes out now
                clk_cnt <= {CW{1'b0}};
                bit_idx <= 4'd0;
                busy    <= 1'b1;
            end
        end else begin
            // SEND: hold each bit for CLKS_PER_BIT cycles
            if (clk_cnt == LAST_CNT) begin
                clk_cnt <= {CW{1'b0}};
                if (bit_idx == 4'd9) begin
                    busy <= 1'b0;             // stop bit done; tx is already 1
                end else begin
                    bit_idx <= bit_idx + 1'b1;
                    tx      <= shreg[bit_idx + 1'b1];
                end
            end else begin
                clk_cnt <= clk_cnt + 1'b1;
            end
        end
    end
endmodule
`default_nettype wire
