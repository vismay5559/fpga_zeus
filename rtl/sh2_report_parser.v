`default_nettype none
// Parse validated SHTP channel-3 packets into the three IMU report banks used
// by the robot. Values remain signed fixed-point integers; the Pi applies Q8,
// Q9 and Q14 scaling.
module sh2_report_parser #(
    parameter integer MAX_PACKET_BYTES = 512
)(
    input  wire clk,
    input  wire rst,
    input  wire snapshot,

    input  wire       packet_start,
    input  wire [7:0] packet_protocol,
    input  wire [$clog2(MAX_PACKET_BYTES+1)-1:0] packet_len,
    input  wire [63:0] packet_capture_us,
    input  wire [7:0] in_data,
    input  wire       in_valid,
    output wire       in_ready,
    input  wire       in_first,
    input  wire       in_last,

    output reg signed [15:0] accel_x,
    output reg signed [15:0] accel_y,
    output reg signed [15:0] accel_z,
    output wire [4:0] accel_q_point,
    output reg [7:0] accel_report_sequence,
    output reg [1:0] accel_status,
    output reg [13:0] accel_delay,
    output reg [7:0] accel_shtp_sequence,
    output reg [63:0] accel_capture_us,
    output reg signed [31:0] accel_base_delta,
    output reg signed [31:0] accel_rebase_delta,
    output reg accel_base_valid,
    output reg accel_has_sample,
    output reg accel_new,

    output reg signed [15:0] gyro_x,
    output reg signed [15:0] gyro_y,
    output reg signed [15:0] gyro_z,
    output wire [4:0] gyro_q_point,
    output reg [7:0] gyro_report_sequence,
    output reg [1:0] gyro_status,
    output reg [13:0] gyro_delay,
    output reg [7:0] gyro_shtp_sequence,
    output reg [63:0] gyro_capture_us,
    output reg signed [31:0] gyro_base_delta,
    output reg signed [31:0] gyro_rebase_delta,
    output reg gyro_base_valid,
    output reg gyro_has_sample,
    output reg gyro_new,

    output reg signed [15:0] rotation_i,
    output reg signed [15:0] rotation_j,
    output reg signed [15:0] rotation_k,
    output reg signed [15:0] rotation_real,
    output reg [15:0] rotation_accuracy,
    output wire [4:0] rotation_q_point,
    output wire [4:0] rotation_accuracy_q_point,
    output reg [7:0] rotation_report_sequence,
    output reg [1:0] rotation_status,
    output reg [13:0] rotation_delay,
    output reg [7:0] rotation_shtp_sequence,
    output reg [63:0] rotation_capture_us,
    output reg signed [31:0] rotation_base_delta,
    output reg signed [31:0] rotation_rebase_delta,
    output reg rotation_base_valid,
    output reg rotation_has_sample,
    output reg rotation_new,

    output reg [31:0] unsupported_report_count,
    output reg [31:0] packet_format_error_count,
    output reg [31:0] ignored_packet_count,
    output reg [31:0] shtp_sequence_gap_count,
    output reg [31:0] accel_sequence_gap_count,
    output reg [31:0] gyro_sequence_gap_count,
    output reg [31:0] rotation_sequence_gap_count
);
    localparam integer CW = $clog2(MAX_PACKET_BYTES + 1);
    localparam integer AW = $clog2(MAX_PACKET_BYTES);
    localparam [CW-1:0] MAX_COUNT = MAX_PACKET_BYTES[CW-1:0];
    localparam [CW-1:0] SIZE_5  = 5;
    localparam [CW-1:0] SIZE_10 = 10;
    localparam [CW-1:0] SIZE_14 = 14;

    localparam [2:0] ST_IDLE    = 3'd0;
    localparam [2:0] ST_RECEIVE = 3'd1;
    localparam [2:0] ST_PREPARE = 3'd2;
    localparam [2:0] ST_SCAN    = 3'd3;
    localparam [2:0] ST_COMMIT  = 3'd4;

    localparam [7:0] REPORT_ACCEL = 8'h01;
    localparam [7:0] REPORT_GYRO  = 8'h02;
    localparam [7:0] REPORT_ROT   = 8'h05;
    localparam [7:0] REPORT_REBASE = 8'hFA;
    localparam [7:0] REPORT_BASE   = 8'hFB;
    localparam [7:0] SENSOR_CHANNEL = 8'd3;

    // TODO 1 (implemented): stage one complete packet before changing any
    // externally visible sensor register. This makes packet updates atomic.
    reg [2:0] state;
    reg [7:0] packet_mem [0:MAX_PACKET_BYTES-1];
    reg [CW-1:0] received_count;
    reg [CW-1:0] scan_index;
    reg [CW-1:0] latched_packet_len;
    reg [7:0] latched_protocol;
    reg [63:0] latched_capture_us;
    reg stream_bad;

    reg signed [31:0] current_base_delta;
    reg signed [31:0] current_rebase_delta;
    reg current_base_valid;

    reg temp_accel_present;
    reg signed [15:0] temp_accel_x, temp_accel_y, temp_accel_z;
    reg [7:0] temp_accel_seq;
    reg [1:0] temp_accel_status;
    reg [13:0] temp_accel_delay;
    reg signed [31:0] temp_accel_base, temp_accel_rebase;
    reg temp_accel_base_valid;

    reg temp_gyro_present;
    reg signed [15:0] temp_gyro_x, temp_gyro_y, temp_gyro_z;
    reg [7:0] temp_gyro_seq;
    reg [1:0] temp_gyro_status;
    reg [13:0] temp_gyro_delay;
    reg signed [31:0] temp_gyro_base, temp_gyro_rebase;
    reg temp_gyro_base_valid;

    reg temp_rotation_present;
    reg signed [15:0] temp_rotation_i, temp_rotation_j;
    reg signed [15:0] temp_rotation_k, temp_rotation_real;
    reg [15:0] temp_rotation_accuracy;
    reg [7:0] temp_rotation_seq;
    reg [1:0] temp_rotation_status;
    reg [13:0] temp_rotation_delay;
    reg signed [31:0] temp_rotation_base, temp_rotation_rebase;
    reg temp_rotation_base_valid;

    reg shtp_sequence_valid;
    reg [7:0] last_shtp_sequence;
    reg accel_sequence_valid, gyro_sequence_valid, rotation_sequence_valid;
    reg [7:0] scan_accel_previous, scan_gyro_previous, scan_rotation_previous;
    reg scan_accel_previous_valid, scan_gyro_previous_valid;
    reg scan_rotation_previous_valid;
    reg [31:0] temp_accel_gaps, temp_gyro_gaps, temp_rotation_gaps;

    // TODO 2 (implemented): accept a byte only on a valid/ready handshake.
    wire input_fire = in_valid && in_ready;
    wire [CW-1:0] last_receive_count = latched_packet_len - 1'b1;
    wire [CW-1:0] bytes_remaining = latched_packet_len - scan_index;
    wire [14:0] latched_length_15 = {{(15-CW){1'b0}}, latched_packet_len};

    assign in_ready = (state == ST_RECEIVE);
    assign accel_q_point = 5'd8;
    assign gyro_q_point = 5'd9;
    assign rotation_q_point = 5'd14;
    assign rotation_accuracy_q_point = 5'd12;

    function automatic [31:0] sat_inc;
        input [31:0] value;
        begin
            sat_inc = (&value) ? value : value + 1'b1;
        end
    endfunction

    function automatic [31:0] sat_add;
        input [31:0] left;
        input [31:0] right;
        reg [32:0] sum;
        begin
            sum = {1'b0, left} + {1'b0, right};
            sat_add = (sum[32]) ? 32'hffffffff : sum[31:0];
        end
    endfunction

    // TODO 3 (implemented): retain the most recent values and clear only the
    // per-report freshness bits when the 1 kHz consumer takes a snapshot.
    always @(posedge clk) begin
        if (rst) begin
            state <= ST_IDLE;
            received_count <= {CW{1'b0}};
            scan_index <= {CW{1'b0}};
            latched_packet_len <= {CW{1'b0}};
            latched_protocol <= 8'd0;
            latched_capture_us <= 64'd0;
            stream_bad <= 1'b0;
            current_base_delta <= 32'sd0;
            current_rebase_delta <= 32'sd0;
            current_base_valid <= 1'b0;

            accel_x <= 16'sd0; accel_y <= 16'sd0; accel_z <= 16'sd0;
            accel_report_sequence <= 8'd0; accel_status <= 2'd0;
            accel_delay <= 14'd0; accel_shtp_sequence <= 8'd0;
            accel_capture_us <= 64'd0; accel_base_delta <= 32'sd0;
            accel_rebase_delta <= 32'sd0; accel_base_valid <= 1'b0;
            accel_has_sample <= 1'b0; accel_new <= 1'b0;

            gyro_x <= 16'sd0; gyro_y <= 16'sd0; gyro_z <= 16'sd0;
            gyro_report_sequence <= 8'd0; gyro_status <= 2'd0;
            gyro_delay <= 14'd0; gyro_shtp_sequence <= 8'd0;
            gyro_capture_us <= 64'd0; gyro_base_delta <= 32'sd0;
            gyro_rebase_delta <= 32'sd0; gyro_base_valid <= 1'b0;
            gyro_has_sample <= 1'b0; gyro_new <= 1'b0;

            rotation_i <= 16'sd0; rotation_j <= 16'sd0;
            rotation_k <= 16'sd0; rotation_real <= 16'sd0;
            rotation_accuracy <= 16'd0; rotation_report_sequence <= 8'd0;
            rotation_status <= 2'd0; rotation_delay <= 14'd0;
            rotation_shtp_sequence <= 8'd0; rotation_capture_us <= 64'd0;
            rotation_base_delta <= 32'sd0; rotation_rebase_delta <= 32'sd0;
            rotation_base_valid <= 1'b0;
            rotation_has_sample <= 1'b0; rotation_new <= 1'b0;

            unsupported_report_count <= 32'd0;
            packet_format_error_count <= 32'd0;
            ignored_packet_count <= 32'd0;
            shtp_sequence_gap_count <= 32'd0;
            accel_sequence_gap_count <= 32'd0;
            gyro_sequence_gap_count <= 32'd0;
            rotation_sequence_gap_count <= 32'd0;
            shtp_sequence_valid <= 1'b0;
            last_shtp_sequence <= 8'd0;
            accel_sequence_valid <= 1'b0;
            gyro_sequence_valid <= 1'b0;
            rotation_sequence_valid <= 1'b0;

            temp_accel_present <= 1'b0; temp_gyro_present <= 1'b0;
            temp_rotation_present <= 1'b0;
            scan_accel_previous <= 8'd0; scan_gyro_previous <= 8'd0;
            scan_rotation_previous <= 8'd0;
            scan_accel_previous_valid <= 1'b0;
            scan_gyro_previous_valid <= 1'b0;
            scan_rotation_previous_valid <= 1'b0;
            temp_accel_gaps <= 32'd0; temp_gyro_gaps <= 32'd0;
            temp_rotation_gaps <= 32'd0;
        end else begin
            // Snapshot consumes old freshness. A commit later in this same
            // clocked block wins, leaving the new sample pending for next time.
            if (snapshot) begin
                accel_new <= 1'b0;
                gyro_new <= 1'b0;
                rotation_new <= 1'b0;
            end

            case (state)
                ST_IDLE: begin
                    if (packet_start) begin
                        latched_protocol   <= packet_protocol;
                        latched_packet_len <= packet_len;
                        latched_capture_us <= packet_capture_us;
                        received_count     <= {CW{1'b0}};
                        stream_bad         <= 1'b0;
                        if (packet_len == 0) begin
                            ignored_packet_count <= sat_inc(ignored_packet_count);
                        end else begin
                            state <= ST_RECEIVE;
                        end
                    end
                end

                // TODO 4 (implemented): copy the deframer's packet bytes into
                // local memory while checking its first/last stream markers.
                ST_RECEIVE: begin
                    if (input_fire) begin
                        if (received_count == MAX_COUNT) begin
                            packet_format_error_count <= sat_inc(packet_format_error_count);
                            state <= ST_IDLE;
                        end else begin
                            packet_mem[received_count[AW-1:0]] <= in_data;
                            if (in_first != (received_count == 0))
                                stream_bad <= 1'b1;
                            if (in_last != (received_count == last_receive_count))
                                stream_bad <= 1'b1;

                            if (in_last) begin
                                received_count <= received_count + 1'b1;
                                state <= ST_PREPARE;
                            end else begin
                                received_count <= received_count + 1'b1;
                            end
                        end
                    end
                end

                // TODO 5 (implemented): verify the SHTP header, continuation
                // bit, channel, byte count and transport protocol before scan.
                ST_PREPARE: begin
                    if (stream_bad || (received_count != latched_packet_len)) begin
                        packet_format_error_count <= sat_inc(packet_format_error_count);
                        state <= ST_IDLE;
                    end else if (latched_protocol != 8'h01) begin
                        ignored_packet_count <= sat_inc(ignored_packet_count);
                        state <= ST_IDLE;
                    end else if (latched_packet_len < 4) begin
                        packet_format_error_count <= sat_inc(packet_format_error_count);
                        state <= ST_IDLE;
                    end else if (packet_mem[1][7]
                        || ({packet_mem[1][6:0], packet_mem[0]} != latched_length_15)) begin
                        packet_format_error_count <= sat_inc(packet_format_error_count);
                        state <= ST_IDLE;
                    end else if (packet_mem[2] != SENSOR_CHANNEL) begin
                        ignored_packet_count <= sat_inc(ignored_packet_count);
                        state <= ST_IDLE;
                    end else begin
                        scan_index <= 4;
                        current_base_delta <= 32'sd0;
                        current_rebase_delta <= 32'sd0;
                        current_base_valid <= 1'b0;
                        temp_accel_present <= 1'b0;
                        temp_gyro_present <= 1'b0;
                        temp_rotation_present <= 1'b0;
                        scan_accel_previous <= accel_report_sequence;
                        scan_gyro_previous <= gyro_report_sequence;
                        scan_rotation_previous <= rotation_report_sequence;
                        scan_accel_previous_valid <= accel_sequence_valid;
                        scan_gyro_previous_valid <= gyro_sequence_valid;
                        scan_rotation_previous_valid <= rotation_sequence_valid;
                        temp_accel_gaps <= 32'd0;
                        temp_gyro_gaps <= 32'd0;
                        temp_rotation_gaps <= 32'd0;
                        state <= ST_SCAN;
                    end
                end

                // TODO 6 (implemented): walk the SH-2 records, preserving the
                // documented little-endian fixed-point integers and metadata.
                ST_SCAN: begin
                    if (scan_index == latched_packet_len) begin
                        state <= ST_COMMIT;
                    end else begin
                        case (packet_mem[scan_index[AW-1:0]])
                            REPORT_BASE: begin
                                if (bytes_remaining < SIZE_5) begin
                                    packet_format_error_count <= sat_inc(packet_format_error_count);
                                    state <= ST_IDLE;
                                end else begin
                                    current_base_delta <= $signed({packet_mem[scan_index+4],
                                        packet_mem[scan_index+3], packet_mem[scan_index+2],
                                        packet_mem[scan_index+1]});
                                    current_rebase_delta <= 32'sd0;
                                    current_base_valid <= 1'b1;
                                    scan_index <= scan_index + SIZE_5;
                                end
                            end

                            REPORT_REBASE: begin
                                if (bytes_remaining < SIZE_5) begin
                                    packet_format_error_count <= sat_inc(packet_format_error_count);
                                    state <= ST_IDLE;
                                end else begin
                                    current_rebase_delta <= $signed({packet_mem[scan_index+4],
                                        packet_mem[scan_index+3], packet_mem[scan_index+2],
                                        packet_mem[scan_index+1]});
                                    scan_index <= scan_index + SIZE_5;
                                end
                            end

                            REPORT_ACCEL: begin
                                if (bytes_remaining < SIZE_10) begin
                                    packet_format_error_count <= sat_inc(packet_format_error_count);
                                    state <= ST_IDLE;
                                end else begin
                                    temp_accel_present <= 1'b1;
                                    temp_accel_seq <= packet_mem[scan_index+1];
                                    temp_accel_status <= packet_mem[scan_index+2][1:0];
                                    temp_accel_delay <= {packet_mem[scan_index+2][7:2],
                                                         packet_mem[scan_index+3]};
                                    temp_accel_x <= $signed({packet_mem[scan_index+5], packet_mem[scan_index+4]});
                                    temp_accel_y <= $signed({packet_mem[scan_index+7], packet_mem[scan_index+6]});
                                    temp_accel_z <= $signed({packet_mem[scan_index+9], packet_mem[scan_index+8]});
                                    temp_accel_base <= current_base_delta;
                                    temp_accel_rebase <= current_rebase_delta;
                                    temp_accel_base_valid <= current_base_valid;
                                    if (scan_accel_previous_valid
                                        && (packet_mem[scan_index+1] != scan_accel_previous + 1'b1))
                                        temp_accel_gaps <= sat_inc(temp_accel_gaps);
                                    scan_accel_previous <= packet_mem[scan_index+1];
                                    scan_accel_previous_valid <= 1'b1;
                                    scan_index <= scan_index + SIZE_10;
                                end
                            end

                            REPORT_GYRO: begin
                                if (bytes_remaining < SIZE_10) begin
                                    packet_format_error_count <= sat_inc(packet_format_error_count);
                                    state <= ST_IDLE;
                                end else begin
                                    temp_gyro_present <= 1'b1;
                                    temp_gyro_seq <= packet_mem[scan_index+1];
                                    temp_gyro_status <= packet_mem[scan_index+2][1:0];
                                    temp_gyro_delay <= {packet_mem[scan_index+2][7:2],
                                                        packet_mem[scan_index+3]};
                                    temp_gyro_x <= $signed({packet_mem[scan_index+5], packet_mem[scan_index+4]});
                                    temp_gyro_y <= $signed({packet_mem[scan_index+7], packet_mem[scan_index+6]});
                                    temp_gyro_z <= $signed({packet_mem[scan_index+9], packet_mem[scan_index+8]});
                                    temp_gyro_base <= current_base_delta;
                                    temp_gyro_rebase <= current_rebase_delta;
                                    temp_gyro_base_valid <= current_base_valid;
                                    if (scan_gyro_previous_valid
                                        && (packet_mem[scan_index+1] != scan_gyro_previous + 1'b1))
                                        temp_gyro_gaps <= sat_inc(temp_gyro_gaps);
                                    scan_gyro_previous <= packet_mem[scan_index+1];
                                    scan_gyro_previous_valid <= 1'b1;
                                    scan_index <= scan_index + SIZE_10;
                                end
                            end

                            REPORT_ROT: begin
                                if (bytes_remaining < SIZE_14) begin
                                    packet_format_error_count <= sat_inc(packet_format_error_count);
                                    state <= ST_IDLE;
                                end else begin
                                    temp_rotation_present <= 1'b1;
                                    temp_rotation_seq <= packet_mem[scan_index+1];
                                    temp_rotation_status <= packet_mem[scan_index+2][1:0];
                                    temp_rotation_delay <= {packet_mem[scan_index+2][7:2],
                                                            packet_mem[scan_index+3]};
                                    temp_rotation_i <= $signed({packet_mem[scan_index+5], packet_mem[scan_index+4]});
                                    temp_rotation_j <= $signed({packet_mem[scan_index+7], packet_mem[scan_index+6]});
                                    temp_rotation_k <= $signed({packet_mem[scan_index+9], packet_mem[scan_index+8]});
                                    temp_rotation_real <= $signed({packet_mem[scan_index+11], packet_mem[scan_index+10]});
                                    temp_rotation_accuracy <= {packet_mem[scan_index+13], packet_mem[scan_index+12]};
                                    temp_rotation_base <= current_base_delta;
                                    temp_rotation_rebase <= current_rebase_delta;
                                    temp_rotation_base_valid <= current_base_valid;
                                    if (scan_rotation_previous_valid
                                        && (packet_mem[scan_index+1] != scan_rotation_previous + 1'b1))
                                        temp_rotation_gaps <= sat_inc(temp_rotation_gaps);
                                    scan_rotation_previous <= packet_mem[scan_index+1];
                                    scan_rotation_previous_valid <= 1'b1;
                                    scan_index <= scan_index + SIZE_14;
                                end
                            end

                            default: begin
                                unsupported_report_count <= sat_inc(unsupported_report_count);
                                state <= ST_IDLE;
                            end
                        endcase
                    end
                end

                // TODO 7 (implemented): publish all staged records together
                // and update freshness, sequence-gap counters and timestamps.
                ST_COMMIT: begin
                    if (shtp_sequence_valid
                        && (packet_mem[3] != last_shtp_sequence + 1'b1))
                        shtp_sequence_gap_count <= sat_inc(shtp_sequence_gap_count);
                    last_shtp_sequence <= packet_mem[3];
                    shtp_sequence_valid <= 1'b1;

                    if (temp_accel_present) begin
                        accel_x <= temp_accel_x; accel_y <= temp_accel_y;
                        accel_z <= temp_accel_z; accel_report_sequence <= temp_accel_seq;
                        accel_status <= temp_accel_status; accel_delay <= temp_accel_delay;
                        accel_shtp_sequence <= packet_mem[3];
                        accel_capture_us <= latched_capture_us;
                        accel_base_delta <= temp_accel_base;
                        accel_rebase_delta <= temp_accel_rebase;
                        accel_base_valid <= temp_accel_base_valid;
                        accel_has_sample <= 1'b1; accel_new <= 1'b1;
                        accel_sequence_valid <= 1'b1;
                        accel_sequence_gap_count <= sat_add(accel_sequence_gap_count,
                                                             temp_accel_gaps);
                    end
                    if (temp_gyro_present) begin
                        gyro_x <= temp_gyro_x; gyro_y <= temp_gyro_y;
                        gyro_z <= temp_gyro_z; gyro_report_sequence <= temp_gyro_seq;
                        gyro_status <= temp_gyro_status; gyro_delay <= temp_gyro_delay;
                        gyro_shtp_sequence <= packet_mem[3];
                        gyro_capture_us <= latched_capture_us;
                        gyro_base_delta <= temp_gyro_base;
                        gyro_rebase_delta <= temp_gyro_rebase;
                        gyro_base_valid <= temp_gyro_base_valid;
                        gyro_has_sample <= 1'b1; gyro_new <= 1'b1;
                        gyro_sequence_valid <= 1'b1;
                        gyro_sequence_gap_count <= sat_add(gyro_sequence_gap_count,
                                                            temp_gyro_gaps);
                    end
                    if (temp_rotation_present) begin
                        rotation_i <= temp_rotation_i; rotation_j <= temp_rotation_j;
                        rotation_k <= temp_rotation_k; rotation_real <= temp_rotation_real;
                        rotation_accuracy <= temp_rotation_accuracy;
                        rotation_report_sequence <= temp_rotation_seq;
                        rotation_status <= temp_rotation_status;
                        rotation_delay <= temp_rotation_delay;
                        rotation_shtp_sequence <= packet_mem[3];
                        rotation_capture_us <= latched_capture_us;
                        rotation_base_delta <= temp_rotation_base;
                        rotation_rebase_delta <= temp_rotation_rebase;
                        rotation_base_valid <= temp_rotation_base_valid;
                        rotation_has_sample <= 1'b1; rotation_new <= 1'b1;
                        rotation_sequence_valid <= 1'b1;
                        rotation_sequence_gap_count <= sat_add(rotation_sequence_gap_count,
                                                                temp_rotation_gaps);
                    end
                    state <= ST_IDLE;
                end

                default: state <= ST_IDLE;
            endcase
        end
    end
endmodule
`default_nettype wire
