`default_nettype none
// Immutable 640-byte snapshot. Fully implemented; TODOs are teaching landmarks.
module pi_snapshot (
    input wire clk, rst, sample,
    input wire [63:0] timestamp_us,
    input wire [31:0] flags,
    input wire [4847:0] payload,
    input wire rewind,
    output wire sample_ready, sample_accepted, busy,
    output reg [31:0] dropped, sequence_next,
    output wire [7:0] out_data,
    output wire out_valid, out_last,
    input wire out_ready
);
    localparam [1:0] IDLE=0, CRC=1, SEND=2;
    reg [1:0] state;
    reg [5119:0] frame;
    reg [9:0] index;
    reg [15:0] crc;
    function [15:0] crc_byte;
        input [15:0] old_crc;
        input [7:0] data;
        reg [15:0] c;
        integer k;
        begin
            c = old_crc ^ {data, 8'b0};
            for (k=0;k<8;k=k+1)
                c = c[15] ? (c << 1) ^ 16'h1021 : (c << 1);
            crc_byte = c;
        end
    endfunction
    wire [15:0] next_crc = crc_byte(crc, frame[index*8 +: 8]);
    // TODO 1 (implemented): capture handshake; producer clears freshness only
    // on sample_accepted, so a dropped snapshot does not consume fresh samples.
    assign sample_ready = state == IDLE && !rst;
    assign sample_accepted = sample && sample_ready;
    assign busy = state != IDLE;
    assign out_valid = state == SEND;
    assign out_data = out_valid ? frame[index*8 +: 8] : 8'b0;
    assign out_last = out_valid && index == 10'd639;
    always @(posedge clk) begin
        if (rst) begin
            state <= IDLE; index <= 0; crc <= 16'hffff;
            dropped <= 0; sequence_next <= 0;
            // Frame RAM need not be reset: it is inaccessible until captured.
        end else begin
            // TODO 2 (implemented): every attempted sample has its own sequence.
            if (sample) begin
                sequence_next <= sequence_next + 1'b1;
                if (!sample_ready && dropped != 32'hffffffff)
                    dropped <= dropped + 1'b1;
            end
            case (state)
                IDLE: if (sample) begin
                    // TODO 3 (implemented): latch the WHOLE payload atomically.
                    // Concatenation is reversed byte order: low bits go first.
                    frame <= {16'b0, payload, 32'b0, flags, dropped,
                              timestamp_us, sequence_next, 16'd640,
                              8'd1, 8'd1, 32'h3150465a};
                    index <= 0; crc <= 16'hffff; state <= CRC;
                end
                CRC: begin
                    // TODO 4 (implemented): one byte per clock, then store CRC LE.
                    crc <= next_crc;
                    if (index == 10'd637) begin
                        frame[5104 +: 16] <= next_crc;
                        index <= 0; state <= SEND;
                    end else index <= index + 1'b1;
                end
                SEND: begin
                    // TODO 5 (implemented): hold all outputs while stalled;
                    // an aborted transport transaction can retry from byte zero.
                    if (rewind) index <= 0;
                    else if (out_ready) begin
                        if (out_last) begin state <= IDLE; index <= 0; end
                        else index <= index + 1'b1;
                    end
                end
                default: state <= IDLE;
            endcase
        end
    end
endmodule
`default_nettype wire
