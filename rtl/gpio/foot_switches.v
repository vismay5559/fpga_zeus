`default_nettype none
// Four STM32-compatible contact switches; all state lives in the system clock.
// Bit order: 0 left toe, 1 left heel, 2 right toe, 3 right heel.
module foot_switches #(
    parameter integer MAKE_TICKS = 3,
    parameter integer BREAK_TICKS = 8
)(
    input wire clk, rst,
    input wire sample,                 // exactly one clock at the 1 kHz boundary
    input wire [3:0] raw_n,           // physical switch: open=1, closed=0
    input wire [63:0] now_us,
    output reg [3:0] switches,
    output wire [1:0] feet,
    output reg [15:0] left_ticks, right_ticks,
    output reg [3:0] switch_changed,
    output reg [1:0] foot_changed,
    output reg [255:0] switch_change_us,
    output reg [63:0] latest_change_us
);
    localparam integer MAX_TICKS = (MAKE_TICKS > BREAK_TICKS) ? MAKE_TICKS : BREAK_TICKS;
    localparam integer CW = (MAX_TICKS < 2) ? 1 : $clog2(MAX_TICKS + 1);
    localparam integer MAKE_I = MAKE_TICKS;
    localparam integer BREAK_I = BREAK_TICKS;
    localparam [CW-1:0] MAKE_NEED = MAKE_I[CW-1:0];
    localparam [CW-1:0] BREAK_NEED = BREAK_I[CW-1:0];
    (* ASYNC_REG = "TRUE" *) reg [3:0] sync_first, sync_second;
    reg [CW-1:0] candidate_ticks [0:3];
    wire [3:0] closed = ~sync_second;
    wire [3:0] next_switches;
    wire [1:0] next_feet;
    genvar g;
    generate for (g=0;g<4;g=g+1) begin : next_state
        wire mismatch = closed[g] != switches[g];
        wire [CW-1:0] needed = closed[g] ? MAKE_NEED : BREAK_NEED;
        wire commit_change = mismatch && (candidate_ticks[g] == needed - 1'b1);
        assign next_switches[g] = commit_change ? closed[g] : switches[g];
    end endgenerate
    assign feet = {switches[3] | switches[2], switches[1] | switches[0]};
    assign next_feet = {next_switches[3] | next_switches[2],
                        next_switches[1] | next_switches[0]};
    integer i;
    always @(posedge clk) begin
        if (rst) begin
            // TODO 1 (implemented): reset both sync stages to idle-high.
            sync_first <= 4'hf;
            sync_second <= 4'hf;
            switches <= 4'b0;
            switch_changed <= 4'b0;
            foot_changed <= 2'b0;
            left_ticks <= 16'd0;
            right_ticks <= 16'd0;
            switch_change_us <= 256'd0;
            latest_change_us <= 64'd0;
            for (i=0;i<4;i=i+1) candidate_ticks[i] <= {CW{1'b0}};
        end else begin
            // TODO 2 (implemented): synchronize raw pins on EVERY clock.
            sync_first <= raw_n;
            sync_second <= sync_first;
            // Event outputs are one clock wide, including across idle cycles.
            switch_changed <= 4'b0;
            foot_changed <= 2'b0;
            if (sample) begin
                // TODO 3 (implemented): independently count consecutive 1 kHz
                // samples of an opposite state. Same-state sample resets count.
                for (i=0;i<4;i=i+1) begin
                    if (closed[i] == switches[i]) candidate_ticks[i] <= {CW{1'b0}};
                    else if (next_switches[i] != switches[i]) begin
                        switches[i] <= closed[i];
                        candidate_ticks[i] <= {CW{1'b0}};
                        switch_changed[i] <= 1'b1;
                        switch_change_us[i*64 +: 64] <= now_us;
                        latest_change_us <= now_us;
                    end else candidate_ticks[i] <= candidate_ticks[i] + 1'b1;
                end
                // TODO 4 (implemented): foot means toe OR heel. A changed
                // switch alone does not reset age if the foot is still down.
                if (next_feet[0] != feet[0]) begin
                    left_ticks <= 0; foot_changed[0] <= 1'b1;
                end else if (left_ticks != 16'hffff) left_ticks <= left_ticks + 1'b1;
                if (next_feet[1] != feet[1]) begin
                    right_ticks <= 0; foot_changed[1] <= 1'b1;
                end else if (right_ticks != 16'hffff) right_ticks <= right_ticks + 1'b1;
            end
        end
    end
endmodule
`default_nettype wire
