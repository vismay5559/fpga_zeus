`default_nettype none
// SHTP-over-UART packet boundary and escape decoder.
//
// Wire format from the BNO08X:
//   0x7E, protocol_id, escaped content bytes, 0x7E
//
// Reserved content bytes are escaped on the wire:
//   0x7E -> 0x7D 0x5E
//   0x7D -> 0x7D 0x5D
//
// Protocol 1 content is an SHTP packet whose first four bytes are:
//   length_lsb, {continuation,length_msb[6:0]}, channel, sequence
// The length includes these four header bytes. This implementation rejects
// continuation packets until a future reassembler is deliberately added.
// Protocol 0 is the UART control channel (BSQ/BSN) and has no SHTP header.
//
// Safety rule: content is first collected into staging memory. Nothing is
// emitted until a closing flag arrives and the complete frame validates.
module shtp_uart_deframer #(
    parameter integer MAX_PACKET_BYTES = 512,
    parameter integer TIMEOUT_CYCLES   = 1000000
)(
    input  wire clk,
    input  wire rst,

    // Input byte stream. Transfer occurs when in_valid && in_ready.
    input  wire [7:0] in_data,
    input  wire       in_valid,
    output wire       in_ready,

    // Abort means an upstream byte was lost or corrupted (for example UART
    // frame_error or FIFO overflow). Any partly collected/emitted packet is
    // discarded, and the deframer hunts for a fresh 0x7E boundary.
    input  wire       stream_abort,

    // A pulse announcing one fully validated packet. packet_len is the count
    // of decoded content bytes that will follow on the output stream.
    output reg        packet_start,
    output reg  [7:0] packet_protocol,
    output reg  [$clog2(MAX_PACKET_BYTES+1)-1:0] packet_len,

    // Valid/ready output stream. out_first/out_last accompany out_data.
    output wire [7:0] out_data,
    output wire       out_valid,
    input  wire       out_ready,
    output wire       out_first,
    output wire       out_last,

    // Saturating diagnostic counters. They clear only on reset.
    output reg [31:0] invalid_protocol_count,
    output reg [31:0] escape_error_count,
    output reg [31:0] length_error_count,
    output reg [31:0] oversize_error_count,
    output reg [31:0] timeout_error_count,
    output reg [31:0] continuation_error_count
);
    // TODO 1 (implemented): Derive counter widths, name every state, and keep
    // one staging RAM large enough for the biggest accepted decoded packet.
    localparam integer CW = $clog2(MAX_PACKET_BYTES + 1);
    localparam integer AW = $clog2(MAX_PACKET_BYTES);
    localparam integer TW = (TIMEOUT_CYCLES <= 1) ? 1 : $clog2(TIMEOUT_CYCLES);
    localparam integer TIMEOUT_LAST_INTEGER = TIMEOUT_CYCLES - 1;
    localparam [CW-1:0] MAX_COUNT = MAX_PACKET_BYTES[CW-1:0];
    localparam [TW-1:0] TIMEOUT_LAST = TIMEOUT_LAST_INTEGER[TW-1:0];

    localparam [2:0] ST_HUNT       = 3'd0;
    localparam [2:0] ST_PROTOCOL   = 3'd1;
    localparam [2:0] ST_COLLECT    = 3'd2;
    localparam [2:0] ST_DROP       = 3'd3;
    localparam [2:0] ST_EMIT_START = 3'd4;
    localparam [2:0] ST_EMIT       = 3'd5;

    localparam [7:0] FLAG = 8'h7E;
    localparam [7:0] ESC  = 8'h7D;

    reg [2:0] state;
    reg [7:0] staging [0:MAX_PACKET_BYTES-1];
    reg [CW-1:0] collect_count;
    reg [AW-1:0] emit_index;
    reg          escape_pending;
    reg          hunt_after_emit;
    reg [TW-1:0] timeout_count;

    // TODO 2 (implemented): Use valid/ready handshakes on both sides. A byte
    // moves only on a clock edge where both signals are high. During emission,
    // keep data and first/last markers stable until the consumer is ready.
    wire input_fire  = in_valid && in_ready;
    wire output_fire = out_valid && out_ready;
    wire [AW-1:0] last_emit_index = packet_len[AW-1:0] - 1'b1;
    wire [14:0] collected_shtp_length = {{(15-CW){1'b0}}, collect_count};

    assign in_ready  = (state != ST_EMIT_START) && (state != ST_EMIT);
    assign out_valid = (state == ST_EMIT);
    assign out_data  = staging[emit_index];
    assign out_first = out_valid && (emit_index == {AW{1'b0}});
    assign out_last  = out_valid && (emit_index == last_emit_index);

    // TODO 3 (implemented): Diagnostic counters saturate at 0xffffffff rather
    // than wrapping to zero and hiding that errors occurred.
    function automatic [31:0] sat_inc;
        input [31:0] value;
        begin
            sat_inc = (&value) ? value : value + 1'b1;
        end
    endfunction

    always @(posedge clk) begin
        packet_start <= 1'b0;

        // TODO 4 (implemented): Reset into boundary-hunt mode and clear all
        // externally visible state and diagnostics.
        if (rst) begin
            state                      <= ST_HUNT;
            collect_count              <= {CW{1'b0}};
            emit_index                 <= {AW{1'b0}};
            escape_pending             <= 1'b0;
            hunt_after_emit             <= 1'b0;
            timeout_count              <= {TW{1'b0}};
            packet_start               <= 1'b0;
            packet_protocol            <= 8'h00;
            packet_len                 <= {CW{1'b0}};
            invalid_protocol_count     <= 32'd0;
            escape_error_count         <= 32'd0;
            length_error_count         <= 32'd0;
            oversize_error_count       <= 32'd0;
            timeout_error_count        <= 32'd0;
            continuation_error_count   <= 32'd0;
        // TODO 5 (implemented): A lost/corrupt upstream byte invalidates the
        // whole current frame. Never join bytes from opposite sides of a loss.
        end else if (stream_abort) begin
            // A packet already in ST_EMIT was fully staged and validated before
            // this newer upstream fault. Finish it without duplicating a byte,
            // then hunt for a fresh boundary. Any packet still being collected
            // is invalid immediately.
            if (state == ST_EMIT_START) begin
                state           <= ST_EMIT;
                hunt_after_emit <= 1'b1;
            end else if (state == ST_EMIT) begin
                if (output_fire) begin
                    if (out_last) begin
                        emit_index      <= {AW{1'b0}};
                        state           <= ST_HUNT;
                        hunt_after_emit <= 1'b0;
                    end else begin
                        emit_index      <= emit_index + 1'b1;
                        hunt_after_emit <= 1'b1;
                    end
                end else begin
                    hunt_after_emit <= 1'b1;
                end
            end else begin
                state           <= ST_HUNT;
                collect_count   <= {CW{1'b0}};
                escape_pending  <= 1'b0;
                hunt_after_emit <= 1'b0;
            end
            timeout_count <= {TW{1'b0}};
        end else begin
            // TODO 6 (implemented): Time out an unfinished frame. The timeout
            // runs only while collecting and restarts on each accepted byte.
            // Timeout applies only after a protocol byte has started a frame.
            // Every accepted wire byte restarts the inactivity timer.
            if (state == ST_COLLECT) begin
                if (input_fire) begin
                    timeout_count <= {TW{1'b0}};
                end else if (timeout_count == TIMEOUT_LAST) begin
                    timeout_error_count <= sat_inc(timeout_error_count);
                    state               <= ST_HUNT;
                    collect_count       <= {CW{1'b0}};
                    escape_pending      <= 1'b0;
                    timeout_count       <= {TW{1'b0}};
                end else begin
                    timeout_count <= timeout_count + 1'b1;
                end
            end else begin
                timeout_count <= {TW{1'b0}};
            end

            case (state)
                // TODO 7 (implemented): Ignore startup garbage until FLAG,
                // accept only protocol 0 or 1, and count invalid protocols.
                ST_HUNT: begin
                    // Ignore arbitrary bytes until an unambiguous boundary.
                    if (input_fire && (in_data == FLAG))
                        state <= ST_PROTOCOL;
                end

                ST_PROTOCOL: begin
                    if (input_fire) begin
                        if (in_data == FLAG) begin
                            // Repeated flags are harmless empty boundaries.
                            state <= ST_PROTOCOL;
                        end else if ((in_data == 8'h00) || (in_data == 8'h01)) begin
                            packet_protocol <= in_data;
                            collect_count   <= {CW{1'b0}};
                            escape_pending  <= 1'b0;
                            state           <= ST_COLLECT;
                        end else begin
                            invalid_protocol_count <= sat_inc(invalid_protocol_count);
                            state                  <= ST_DROP;
                        end
                    end
                end

                // TODO 8 (implemented): Decode escapes into staging RAM. At
                // the closing FLAG, validate the complete SHTP header, length,
                // continuation bit, and size before announcing any packet.
                ST_COLLECT: begin
                    if (input_fire) begin
                        if (in_data == FLAG) begin
                            if (escape_pending) begin
                                // ESC immediately followed by FLAG is truncated.
                                escape_error_count <= sat_inc(escape_error_count);
                                state              <= ST_PROTOCOL;
                            end else if (packet_protocol == 8'h00) begin
                                // UART control messages have no four-byte SHTP
                                // header, so framing and the size bound suffice.
                                packet_len   <= collect_count;
                                packet_start <= 1'b1;
                                emit_index   <= {AW{1'b0}};
                                hunt_after_emit <= 1'b0;
                                state        <= (collect_count == 0)
                                                  ? ST_PROTOCOL : ST_EMIT_START;
                            end else if (collect_count < 4) begin
                                length_error_count <= sat_inc(length_error_count);
                                state              <= ST_PROTOCOL;
                            end else if (staging[1][7]) begin
                                continuation_error_count <= sat_inc(continuation_error_count);
                                state                    <= ST_PROTOCOL;
                            end else if ({staging[1][6:0], staging[0]} != collected_shtp_length) begin
                                length_error_count <= sat_inc(length_error_count);
                                state              <= ST_PROTOCOL;
                            end else begin
                                packet_len   <= collect_count;
                                packet_start <= 1'b1;
                                emit_index   <= {AW{1'b0}};
                                hunt_after_emit <= 1'b0;
                                state        <= ST_EMIT_START;
                            end
                            collect_count  <= {CW{1'b0}};
                            escape_pending <= 1'b0;
                        end else if (escape_pending) begin
                            if ((in_data == 8'h5E) || (in_data == 8'h5D)) begin
                                if (collect_count == MAX_COUNT) begin
                                    oversize_error_count <= sat_inc(oversize_error_count);
                                    state                <= ST_DROP;
                                end else begin
                                    staging[collect_count[AW-1:0]] <= in_data ^ 8'h20;
                                    collect_count <= collect_count + 1'b1;
                                end
                            end else begin
                                escape_error_count <= sat_inc(escape_error_count);
                                state              <= ST_DROP;
                            end
                            escape_pending <= 1'b0;
                        end else if (in_data == ESC) begin
                            escape_pending <= 1'b1;
                        end else if (collect_count == MAX_COUNT) begin
                            oversize_error_count <= sat_inc(oversize_error_count);
                            state                <= ST_DROP;
                        end else begin
                            staging[collect_count[AW-1:0]] <= in_data;
                            collect_count <= collect_count + 1'b1;
                        end
                    end
                end

                // TODO 9 (implemented): After malformed input, discard bytes
                // until the next FLAG gives an unambiguous new boundary.
                ST_DROP: begin
                    // Discard the damaged frame. Its closing delimiter also
                    // becomes a safe possible opening boundary for the next.
                    if (input_fire && (in_data == FLAG)) begin
                        state          <= ST_PROTOCOL;
                        collect_count  <= {CW{1'b0}};
                        escape_pending <= 1'b0;
                    end
                end

                // TODO 10 (implemented): Emit a validated staged packet under
                // backpressure. out_last ends it; the closing FLAG also serves
                // as the possible opening boundary of the following frame.
                ST_EMIT_START: begin
                    // One separating cycle makes packet_start unambiguous: all
                    // output bytes begin on following cycles.
                    state <= ST_EMIT;
                end

                ST_EMIT: begin
                    if (output_fire) begin
                        if (out_last) begin
                            emit_index <= {AW{1'b0}};
                            // The closing flag already provided a boundary.
                            state      <= hunt_after_emit ? ST_HUNT : ST_PROTOCOL;
                            hunt_after_emit <= 1'b0;
                        end else begin
                            emit_index <= emit_index + 1'b1;
                        end
                    end
                end

                default: begin
                    state          <= ST_HUNT;
                    collect_count  <= {CW{1'b0}};
                    escape_pending <= 1'b0;
                end
            endcase
        end
    end
endmodule
`default_nettype wire
