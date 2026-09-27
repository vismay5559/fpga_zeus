`default_nettype none
// BNO085-specific UART packet transmitter. It adds UART-SHTP framing, escapes
// reserved content bytes and leaves a programmable quiet interval after every
// physical wire byte, including flags, escape bytes and the final packet byte.
module bno085_uart_packet_tx #(
    parameter integer CLK_HZ         = 100000000,
    parameter integer CLKS_PER_BIT   = 33,
    parameter integer TX_BYTE_GAP_US = 120,
    parameter integer MAX_PAYLOAD    = 64
)(
    input  wire clk,
    input  wire rst,

    input  wire request_valid,
    output wire request_ready,
    input  wire request_bsq,
    input  wire [7:0] request_channel,
    input  wire [$clog2(MAX_PAYLOAD+1)-1:0] request_payload_len,
    output wire [$clog2(MAX_PAYLOAD+1)-1:0] payload_index,
    input  wire [7:0] payload_byte,

    output wire tx,
    output reg  busy,
    output reg  done,
    output reg [31:0] packet_count,
    output reg [31:0] wire_byte_count
);
    localparam integer PW = $clog2(MAX_PAYLOAD + 1);
    localparam integer GAP_CYCLES_I = (CLK_HZ / 1000000) * TX_BYTE_GAP_US;
    localparam integer GW = (GAP_CYCLES_I <= 2) ? 1 : $clog2(GAP_CYCLES_I);
    localparam integer GAP_WAIT_I = (GAP_CYCLES_I <= 2) ? 0 : GAP_CYCLES_I - 2;
    localparam [GW-1:0] GAP_WAIT = GAP_WAIT_I[GW-1:0];
    localparam [PW-1:0] PAYLOAD_OFFSET = 4;

    localparam [2:0] GEN_IDLE    = 3'd0;
    localparam [2:0] GEN_FLAG    = 3'd1;
    localparam [2:0] GEN_PROTO   = 3'd2;
    localparam [2:0] GEN_CONTENT = 3'd3;
    localparam [2:0] GEN_CLOSE   = 3'd4;

    localparam [7:0] FLAG = 8'h7e;
    localparam [7:0] ESC  = 8'h7d;

    reg [2:0] gen_state;
    reg latched_bsq;
    reg [7:0] latched_channel;
    reg [PW-1:0] latched_payload_len;
    reg [PW:0] logical_index;
    reg [7:0] latched_sequence;
    reg [7:0] channel_sequence [0:7];
    reg escape_second;

    reg byte_inflight;
    reg final_byte_accepted;
    reg final_waiting;
    reg gap_active;
    reg [GW-1:0] gap_count;

    wire uart_ready;
    wire [PW:0] shtp_length = latched_payload_len + 4;
    wire [PW:0] content_count = latched_payload_len + 4;
    reg [7:0] logical_byte;
    reg [7:0] wire_byte;

    // TODO 1 (implemented): expose the payload address while the header and
    // payload are streamed. The producer keeps this byte stable until used.
    assign payload_index = (logical_index >= 4)
                         ? logical_index[PW-1:0] - PAYLOAD_OFFSET
                         : {PW{1'b0}};

    always @* begin
        case (logical_index)
            0: logical_byte = shtp_length[7:0];
            1: logical_byte = shtp_length >> 8;
            2: logical_byte = latched_channel;
            3: logical_byte = latched_sequence;
            default: logical_byte = payload_byte;
        endcase

        case (gen_state)
            GEN_FLAG, GEN_CLOSE: wire_byte = FLAG;
            GEN_PROTO: wire_byte = latched_bsq ? 8'h00 : 8'h01;
            GEN_CONTENT: begin
                if (escape_second)
                    wire_byte = logical_byte ^ 8'h20;
                else if ((logical_byte == FLAG) || (logical_byte == ESC))
                    wire_byte = ESC;
                else
                    wire_byte = logical_byte;
            end
            default: wire_byte = 8'hff;
        endcase
    end

    // TODO 2 (implemented): only offer a byte while the generic UART is idle
    // and the mandatory post-stop-bit quiet interval has elapsed.
    wire uart_valid = busy && !byte_inflight && !gap_active
                    && (gen_state != GEN_IDLE) && !final_waiting;
    assign request_ready = !busy;

    uart_tx #(.CLKS_PER_BIT(CLKS_PER_BIT)) physical_uart (
        .clk(clk), .rst(rst), .data(wire_byte), .valid(uart_valid),
        .ready(uart_ready), .tx(tx)
    );

    always @(posedge clk) begin
        if (rst) begin
            gen_state <= GEN_IDLE;
            latched_bsq <= 1'b0;
            latched_channel <= 8'd0;
            latched_payload_len <= {PW{1'b0}};
            logical_index <= {(PW+1){1'b0}};
            latched_sequence <= 8'd0;
            escape_second <= 1'b0;
            byte_inflight <= 1'b0;
            final_byte_accepted <= 1'b0;
            final_waiting <= 1'b0;
            gap_active <= 1'b0;
            gap_count <= {GW{1'b0}};
            busy <= 1'b0;
            done <= 1'b0;
            packet_count <= 32'd0;
            wire_byte_count <= 32'd0;
            channel_sequence[0] <= 8'd0;
            channel_sequence[1] <= 8'd0;
            channel_sequence[2] <= 8'd0;
            channel_sequence[3] <= 8'd0;
            channel_sequence[4] <= 8'd0;
            channel_sequence[5] <= 8'd0;
            channel_sequence[6] <= 8'd0;
            channel_sequence[7] <= 8'd0;
        end else begin
            done <= 1'b0;

            // TODO 3 (implemented): latch one request. Sequence numbers are
            // independent for every SHTP channel and BSQ does not consume one.
            if (request_valid && request_ready) begin
                latched_bsq <= request_bsq;
                latched_channel <= request_channel;
                latched_payload_len <= request_payload_len;
                logical_index <= {(PW+1){1'b0}};
                escape_second <= 1'b0;
                final_byte_accepted <= 1'b0;
                final_waiting <= 1'b0;
                busy <= 1'b1;
                gen_state <= GEN_FLAG;
                if (!request_bsq) begin
                    latched_sequence <= channel_sequence[request_channel[2:0]];
                    channel_sequence[request_channel[2:0]]
                        <= channel_sequence[request_channel[2:0]] + 1'b1;
                end
            end

            // TODO 4 (implemented): once uart_tx accepts a wire byte, advance
            // the framing/escaping generator while uart_tx shifts that byte.
            if (uart_valid && uart_ready) begin
                byte_inflight <= 1'b1;
                wire_byte_count <= (&wire_byte_count)
                                 ? wire_byte_count : wire_byte_count + 1'b1;
                case (gen_state)
                    GEN_FLAG: gen_state <= GEN_PROTO;
                    GEN_PROTO: begin
                        if (latched_bsq)
                            gen_state <= GEN_CLOSE;
                        else
                            gen_state <= GEN_CONTENT;
                    end
                    GEN_CONTENT: begin
                        if (!escape_second
                            && ((logical_byte == FLAG) || (logical_byte == ESC))) begin
                            escape_second <= 1'b1;
                        end else begin
                            escape_second <= 1'b0;
                            if (logical_index + 1'b1 == content_count)
                                gen_state <= GEN_CLOSE;
                            else
                                logical_index <= logical_index + 1'b1;
                        end
                    end
                    GEN_CLOSE: begin
                        gen_state <= GEN_IDLE;
                        final_byte_accepted <= 1'b1;
                    end
                    default: gen_state <= GEN_IDLE;
                endcase
            end

            // TODO 5 (implemented): uart_ready returns high only after the stop
            // bit finishes. Start the inter-byte timer at that point.
            if (byte_inflight && uart_ready) begin
                byte_inflight <= 1'b0;
                gap_count <= GAP_WAIT;
                gap_active <= (GAP_CYCLES_I > 1);
                if (final_byte_accepted) begin
                    final_byte_accepted <= 1'b0;
                    final_waiting <= 1'b1;
                end
            end else if (gap_active) begin
                if (gap_count <= 1) begin
                    gap_count <= {GW{1'b0}};
                    gap_active <= 1'b0;
                    if (final_waiting) begin
                        final_waiting <= 1'b0;
                        busy <= 1'b0;
                        done <= 1'b1;
                        packet_count <= (&packet_count)
                                      ? packet_count : packet_count + 1'b1;
                    end
                end else begin
                    gap_count <= gap_count - 1'b1;
                end
            end else if (final_waiting) begin
                final_waiting <= 1'b0;
                busy <= 1'b0;
                done <= 1'b1;
                packet_count <= (&packet_count)
                              ? packet_count : packet_count + 1'b1;
            end
        end
    end
endmodule
`default_nettype wire
