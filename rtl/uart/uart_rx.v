`default_nettype none
// 8N1 UART receiver. See sim/test_uart_rx.py for the full spec.
module uart_rx #(
    parameter integer CLKS_PER_BIT = 33
)(
    input  wire       clk,
    input  wire       rst,          // synchronous, active high
    input  wire       rx,           // serial line, asynchronous to clk
    output reg  [7:0] data,         // received byte, held until the next one
    output reg        valid,        // ONE cycle high when data is good
    output reg        frame_error   // ONE cycle high when the stop bit was 0
);
    localparam integer  CW       = $clog2(CLKS_PER_BIT);
    localparam integer  LAST_I   = CLKS_PER_BIT - 1;      // end of a full bit
    localparam integer  HALF_I   = CLKS_PER_BIT / 2 - 1;  // middle of a bit
    localparam [CW-1:0] LAST_CNT = LAST_I[CW-1:0];
    localparam [CW-1:0] HALF_CNT = HALF_I[CW-1:0];

    reg [1:0]    sync;       // 2-flop synchronizer for the async rx pin
    wire         rx_s = sync[1];   // the safe, synchronized version of rx

    reg          busy;      // 1 while a frame is being received
    reg          armed;     // 1 after idle-high has been seen; permits a new start
    reg [CW-1:0] clk_cnt;   // cycles elapsed inside the current bit
    reg [3:0]    bit_idx;   // 0 = start bit, 1..8 = data bits, 9 = stop bit
    reg [7:0]    shreg;     // bits collected so far

    always @(posedge clk) begin
        sync        <= {sync[0], rx};   // runs every cycle, even during reset
        valid       <= 1'b0;            // default: pulse only when told to below
        frame_error <= 1'b0;

        if (rst) begin
            sync    <= 2'b11;           // pretend the line is idle
            busy    <= 1'b0;
            armed   <= 1'b0;
            // TODO 1: reset the counters
            clk_cnt <= {CW{1'b0}};
            bit_idx <= 4'd0;
        end else if (!busy) begin
            // TODO 2: IDLE - first see the line high to arm the receiver. Once
            //         armed, a low level is a NEW falling edge/start bit: clear
            //         the counters, disarm, and go busy. Requiring high first
            //         prevents a bad low stop bit from becoming a phantom frame.
            if (rx_s) begin
                armed <= 1'b1;
            end else if (armed) begin
                busy    <= 1'b1;
                armed   <= 1'b0;
                clk_cnt <= {CW{1'b0}};
                bit_idx <= 4'd0;
            end
        end else if (bit_idx == 4'd0) begin
            // TODO 3: START BIT - count to HALF_CNT to reach the middle of the bit.
            //         There, if the line is high again it was a glitch, so go back to
            //         idle. If it is still low, clear clk_cnt and move to bit_idx 1.
            if (clk_cnt == HALF_CNT) begin
                clk_cnt <= {CW{1'b0}};
                if (rx_s) busy    <= 1'b0;   // glitch, not a real start bit
                else      bit_idx <= 4'd1;   // real start bit, on to the data bits
            end else begin
                clk_cnt <= clk_cnt + 1'b1;
            end
        end else begin
            // TODO 4: DATA AND STOP BITS - count to LAST_CNT; each time you get there
            //         you are in the middle of the next bit.
            //           bit_idx 1..8 : shift rx_s into shreg (LSB arrives first) and
            //                          step bit_idx on
            //           bit_idx 9    : the stop bit. High -> copy shreg to data and
            //                          pulse valid. Low -> pulse frame_error.
            //                          Either way the frame is over, so clear busy.
            if (clk_cnt == LAST_CNT) begin
                clk_cnt <= {CW{1'b0}};
                if (bit_idx == 4'd9) begin
                    busy <= 1'b0;
                    if (rx_s) begin
                        data  <= shreg;
                        valid <= 1'b1;
                    end else begin
                        frame_error <= 1'b1;
                    end
                end else begin
                    shreg   <= {rx_s, shreg[7:1]};
                    bit_idx <= bit_idx + 1'b1;
                end
            end else begin
                clk_cnt <= clk_cnt + 1'b1;
            end
        end
    end
endmodule
`default_nettype wire
