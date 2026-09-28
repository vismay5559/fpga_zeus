`default_nettype none
// Arty bench top: live BNO085 IMU and foot contacts; encoder/CAN fields invalid.
// TEST_MODE marks this as a demo. Motor commands are not implemented.
module pi_link_demo_top #(
    parameter integer CLKS_PER_US = 100,
    parameter integer POR_BITS = 16,
    parameter integer IMU_CLKS_PER_BIT = 33,
    parameter integer IMU_FIFO_DEPTH = 16,
    parameter integer IMU_MAX_PACKET_BYTES = 128,
    parameter integer IMU_TIMEOUT_CYCLES = 1000000,
    parameter integer IMU_CLK_HZ = 100000000,
    parameter integer IMU_TX_BYTE_GAP_US = 120,
    parameter integer IMU_FEATURE_GAP_US = 5000,
    parameter integer IMU_RESPONSE_TIMEOUT_US = 100000
)(
    input wire CLK100MHZ,
    input wire [0:0] btn,
    input wire [1:0] foot_sw_n,
    input wire imu_rx,                 // BNO085 UART TX -> FPGA
    output wire imu_tx,               // FPGA -> BNO085 UART RX
    output wire [2:0] led,
    input wire pi_sck, pi_cs_n,
    output wire pi_miso, pi_data_ready
);
    reg [POR_BITS-1:0] por_count = 0;
    (* ASYNC_REG = "TRUE" *) reg [1:0] btn_sync = 0;
    always @(posedge CLK100MHZ) begin
        btn_sync <= {btn_sync[0], btn[0]};
        if (!(&por_count)) por_count <= por_count + 1'b1;
    end
    wire rst = !(&por_count) || btn_sync[1];
    wire sample;
    reg sample_for_link;
    wire [63:0] timestamp_us;
    wire [1:0] switches, unused_switch_changed;
    wire [1:0] feet, unused_foot_changed;
    wire [15:0] left_ticks, right_ticks;
    wire [63:0] latest_change_us;
    wire [127:0] unused_switch_change_us;
    wire [127:0] contact_record;
    wire [319:0] accel_record, gyro_record, rotation_record;
    reg [4847:0] payload;
    wire miso;
    wire unused_ready, sample_accepted;
    wire [31:0] unused_dropped, unused_sequence;
    wire configured;
    wire unused_configuring, unused_tx_busy;
    wire unused_rotation_confirmed, unused_accel_confirmed, unused_gyro_confirmed;
    wire [31:0] sensor_reset_count;
    wire [31:0] bsn_query_count;
    wire [31:0] bsn_timeout_count;
    wire [31:0] config_retry_count;
    wire [31:0] confirmation_error_count;
    wire [31:0] advertised_uart_timeout_ms;
    wire signed [15:0] accel_x, accel_y, accel_z;
    wire [4:0] accel_q_point;
    wire [7:0] accel_report_sequence;
    wire [1:0] accel_status;
    wire [13:0] accel_delay;
    wire [7:0] accel_shtp_sequence;
    wire [63:0] accel_capture_us;
    wire signed [31:0] accel_base_delta, accel_rebase_delta;
    wire accel_base_valid, accel_has_sample, accel_new;
    wire signed [15:0] gyro_x, gyro_y, gyro_z;
    wire [4:0] gyro_q_point;
    wire [7:0] gyro_report_sequence;
    wire [1:0] gyro_status;
    wire [13:0] gyro_delay;
    wire [7:0] gyro_shtp_sequence;
    wire [63:0] gyro_capture_us;
    wire signed [31:0] gyro_base_delta, gyro_rebase_delta;
    wire gyro_base_valid, gyro_has_sample, gyro_new;
    wire signed [15:0] rotation_i, rotation_j;
    wire signed [15:0] rotation_k, rotation_real;
    wire [15:0] rotation_accuracy;
    wire [4:0] rotation_q_point, rotation_accuracy_q_point;
    wire [7:0] rotation_report_sequence;
    wire [1:0] rotation_status;
    wire [13:0] rotation_delay;
    wire [7:0] rotation_shtp_sequence;
    wire [63:0] rotation_capture_us;
    wire signed [31:0] rotation_base_delta, rotation_rebase_delta;
    wire rotation_base_valid, rotation_has_sample, rotation_new;
    wire [31:0] uart_frame_error_count;
    wire [31:0] fifo_overflow_count;
    wire [31:0] invalid_protocol_count;
    wire [31:0] escape_error_count;
    wire [31:0] length_error_count;
    wire [31:0] oversize_error_count;
    wire [31:0] timeout_error_count;
    wire [31:0] continuation_error_count;
    wire [31:0] unsupported_report_count;
    wire [31:0] packet_format_error_count;
    wire [31:0] ignored_packet_count;
    wire [31:0] shtp_sequence_gap_count;
    wire [31:0] accel_sequence_gap_count;
    wire [31:0] gyro_sequence_gap_count;
    wire [31:0] rotation_sequence_gap_count;

    cycle_timer #(.CLKS_PER_US(CLKS_PER_US)) timer (
        .clk(CLK100MHZ), .rst(rst), .sample(sample),
        .timestamp_us(timestamp_us)
    );
    foot_switches contacts (
        .clk(CLK100MHZ), .rst(rst), .sample(sample),
        .raw_n(foot_sw_n), .now_us(timestamp_us),
        .switches(switches), .feet(feet),
        .left_ticks(left_ticks), .right_ticks(right_ticks),
        .switch_changed(unused_switch_changed),
        .foot_changed(unused_foot_changed),
        .switch_change_us(unused_switch_change_us),
        .latest_change_us(latest_change_us)
    );
    bno085_imu #(
        .CLKS_PER_BIT(IMU_CLKS_PER_BIT), .FIFO_DEPTH(IMU_FIFO_DEPTH),
        .MAX_PACKET_BYTES(IMU_MAX_PACKET_BYTES),
        .TIMEOUT_CYCLES(IMU_TIMEOUT_CYCLES), .CLKS_PER_US(CLKS_PER_US),
        .CLK_HZ(IMU_CLK_HZ), .TX_BYTE_GAP_US(IMU_TX_BYTE_GAP_US),
        .FEATURE_GAP_US(IMU_FEATURE_GAP_US),
        .RESPONSE_TIMEOUT_US(IMU_RESPONSE_TIMEOUT_US)
    ) imu (
        .clk(CLK100MHZ), .rst(rst), .rx(imu_rx), .tx(imu_tx),
        // Freshness clears only when a snapshot is accepted.
        .snapshot(sample_accepted),
        .configured(configured),
        .configuring(unused_configuring),
        .tx_busy(unused_tx_busy),
        .sensor_reset_count(sensor_reset_count),
        .bsn_query_count(bsn_query_count),
        .bsn_timeout_count(bsn_timeout_count),
        .config_retry_count(config_retry_count),
        .confirmation_error_count(confirmation_error_count),
        .advertised_uart_timeout_ms(advertised_uart_timeout_ms),
        .rotation_confirmed(unused_rotation_confirmed),
        .accel_confirmed(unused_accel_confirmed),
        .gyro_confirmed(unused_gyro_confirmed),
        .accel_x(accel_x),
        .accel_y(accel_y),
        .accel_z(accel_z),
        .accel_q_point(accel_q_point),
        .accel_report_sequence(accel_report_sequence),
        .accel_status(accel_status),
        .accel_delay(accel_delay),
        .accel_shtp_sequence(accel_shtp_sequence),
        .accel_capture_us(accel_capture_us),
        .accel_base_delta(accel_base_delta),
        .accel_rebase_delta(accel_rebase_delta),
        .accel_base_valid(accel_base_valid),
        .accel_has_sample(accel_has_sample),
        .accel_new(accel_new),
        .gyro_x(gyro_x),
        .gyro_y(gyro_y),
        .gyro_z(gyro_z),
        .gyro_q_point(gyro_q_point),
        .gyro_report_sequence(gyro_report_sequence),
        .gyro_status(gyro_status),
        .gyro_delay(gyro_delay),
        .gyro_shtp_sequence(gyro_shtp_sequence),
        .gyro_capture_us(gyro_capture_us),
        .gyro_base_delta(gyro_base_delta),
        .gyro_rebase_delta(gyro_rebase_delta),
        .gyro_base_valid(gyro_base_valid),
        .gyro_has_sample(gyro_has_sample),
        .gyro_new(gyro_new),
        .rotation_i(rotation_i),
        .rotation_j(rotation_j),
        .rotation_k(rotation_k),
        .rotation_real(rotation_real),
        .rotation_accuracy(rotation_accuracy),
        .rotation_q_point(rotation_q_point),
        .rotation_accuracy_q_point(rotation_accuracy_q_point),
        .rotation_report_sequence(rotation_report_sequence),
        .rotation_status(rotation_status),
        .rotation_delay(rotation_delay),
        .rotation_shtp_sequence(rotation_shtp_sequence),
        .rotation_capture_us(rotation_capture_us),
        .rotation_base_delta(rotation_base_delta),
        .rotation_rebase_delta(rotation_rebase_delta),
        .rotation_base_valid(rotation_base_valid),
        .rotation_has_sample(rotation_has_sample),
        .rotation_new(rotation_new),
        .uart_frame_error_count(uart_frame_error_count),
        .fifo_overflow_count(fifo_overflow_count),
        .invalid_protocol_count(invalid_protocol_count),
        .escape_error_count(escape_error_count),
        .length_error_count(length_error_count),
        .oversize_error_count(oversize_error_count),
        .timeout_error_count(timeout_error_count),
        .continuation_error_count(continuation_error_count),
        .unsupported_report_count(unsupported_report_count),
        .packet_format_error_count(packet_format_error_count),
        .ignored_packet_count(ignored_packet_count),
        .shtp_sequence_gap_count(shtp_sequence_gap_count),
        .accel_sequence_gap_count(accel_sequence_gap_count),
        .gyro_sequence_gap_count(gyro_sequence_gap_count),
        .rotation_sequence_gap_count(rotation_sequence_gap_count)
    );
    // The GPIO bank updates on `sample`; capture it one clock afterward.
    always @(posedge CLK100MHZ) begin
        if (rst) sample_for_link <= 1'b0;
        else sample_for_link <= sample;
    end
    // Three little-endian 40-byte ZFP1 IMU records.
    assign accel_record = {
        32'b0,
        accel_rebase_delta,
        accel_base_delta,
        accel_capture_us,
        16'b0,
        {2'b0, accel_delay},
        accel_shtp_sequence,
        accel_report_sequence,
        {6'b0, accel_status},
        8'b0,
        {3'b0, accel_q_point},
        {5'b0, accel_base_valid, accel_new, accel_has_sample},
        16'b0,
        16'b0,
        accel_z,
        accel_y,
        accel_x
    };
    assign gyro_record = {
        32'b0,
        gyro_rebase_delta,
        gyro_base_delta,
        gyro_capture_us,
        16'b0,
        {2'b0, gyro_delay},
        gyro_shtp_sequence,
        gyro_report_sequence,
        {6'b0, gyro_status},
        8'b0,
        {3'b0, gyro_q_point},
        {5'b0, gyro_base_valid, gyro_new, gyro_has_sample},
        16'b0,
        16'b0,
        gyro_z,
        gyro_y,
        gyro_x
    };
    assign rotation_record = {
        32'b0,
        rotation_rebase_delta,
        rotation_base_delta,
        rotation_capture_us,
        16'b0,
        {2'b0, rotation_delay},
        rotation_shtp_sequence,
        rotation_report_sequence,
        {6'b0, rotation_status},
        {3'b0, rotation_accuracy_q_point},
        {3'b0, rotation_q_point},
        {5'b0, rotation_base_valid, rotation_new, rotation_has_sample},
        rotation_accuracy,
        rotation_real,
        rotation_k,
        rotation_j,
        rotation_i
    };
    // Relative packet byte432 = absolute frame byte464.
    assign contact_record = {
        latest_change_us, right_ticks, left_ticks, 16'b0,
        6'b0, feet, 6'b0, switches
    };
    always @* begin
        payload = 4848'b0;
        payload[0 +: 320] = accel_record;       // frame bytes 32..71
        payload[320 +: 320] = gyro_record;     // frame bytes 72..111
        payload[640 +: 320] = rotation_record; // frame bytes 112..151
        payload[3456 +: 128] = contact_record;
        // IMU diagnostics frame bytes 480..559; advertised timeout at 608.
        payload[3584 +: 32] = uart_frame_error_count;
        payload[3616 +: 32] = fifo_overflow_count;
        payload[3648 +: 32] = invalid_protocol_count;
        payload[3680 +: 32] = escape_error_count;
        payload[3712 +: 32] = length_error_count;
        payload[3744 +: 32] = oversize_error_count;
        payload[3776 +: 32] = timeout_error_count;
        payload[3808 +: 32] = continuation_error_count;
        payload[3840 +: 32] = unsupported_report_count;
        payload[3872 +: 32] = packet_format_error_count;
        payload[3904 +: 32] = ignored_packet_count;
        payload[3936 +: 32] = shtp_sequence_gap_count;
        payload[3968 +: 32] = accel_sequence_gap_count;
        payload[4000 +: 32] = gyro_sequence_gap_count;
        payload[4032 +: 32] = rotation_sequence_gap_count;
        payload[4064 +: 32] = sensor_reset_count;
        payload[4096 +: 32] = bsn_query_count;
        payload[4128 +: 32] = bsn_timeout_count;
        payload[4160 +: 32] = config_retry_count;
        payload[4192 +: 32] = confirmation_error_count;
        payload[576*8 +: 32] = advertised_uart_timeout_ms;
    end
    pi_link link (
        .clk(CLK100MHZ), .rst(rst), .sample(sample_for_link),
        .timestamp_us(timestamp_us),
        .flags(32'h80000004 | {31'b0, configured}),
        .payload(payload), .spi_sck(pi_sck), .spi_cs_n(pi_cs_n),
        .spi_miso(miso), .data_ready(pi_data_ready),
        .sample_ready(unused_ready), .sample_accepted(sample_accepted),
        .dropped(unused_dropped), .sequence_next(unused_sequence)
    );
    assign pi_miso = pi_cs_n ? 1'bz : miso;
    assign led[0] = pi_data_ready;
    assign led[1] = feet[0];
    assign led[2] = feet[1];
endmodule
`default_nettype wire
