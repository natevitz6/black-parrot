/**
 *
 * Name:
 *   bp_uce_multi_pre.sv
 *
 * Description:
 *   This is the UCE side L2 prefetch request generator
 *
 */

`include "bp_common_defines.svh"
`include "bp_me_defines.svh"

module bp_uce_multi_pre
  import bp_common_pkg::*;
  import bp_me_pkg::*;
  #(parameter bp_params_e bp_params_p = e_bp_default_cfg
    , parameter streams_p = "inv"
    , parameter addr_width_p = "inv"
    , parameter block_offset_width_p = "inv"
    , parameter miss_count = "inv"
    , parameter lookahead_depth = "inv"
    )
   (input clk_i
     , input reset_i

     , input req_v_i
     , input miss_i
     , input hit_i
     , input [addr_width_p-1:0] req_addr_i

     , output logic prefetch_v_o
     , output logic [addr_width_p-1:0] prefetch_addr_o
     , input prefetch_yumi_i
    );
  
  localparam int stream_idx_width_lp = (streams_p > 1) ? $clog2(streams_p) : 1;

  localparam logic [addr_width_p-1:0] line_size_lp =
    (addr_width_p'(1) << block_offset_width_p);

  logic prefetch_v_r, prefetch_v_n;
  logic [streams_p-1:0] stream_active_r, stream_active_n;

  logic [streams_p-1:0][$clog2(lookahead_depth+1)-1:0] remaining_prefetches_r, remaining_prefetches_n;

  logic [streams_p-1:0][$clog2(miss_count+1)-1:0] count_r, count_n;

  logic [streams_p-1:0][addr_width_p-1:0] prefetch_addr_r, prefetch_addr_n;
  // Tracks next expected miss for training and moves to next address after latest prefetch is accepted
  logic [streams_p-1:0][addr_width_p-1:0] expected_miss_addr_r, expected_miss_addr_n;
  logic [streams_p-1:0][addr_width_p-1:0] expected_hit_addr_r, expected_hit_addr_n;

  // Registered miss and hit observation stage
  logic miss_v_r, miss_v_n, hit_v_r, hit_v_n;
  logic [addr_width_p-1:0] miss_addr_r, miss_addr_n, hit_addr_n, hit_addr_r;

  logic [streams_p-1:0] miss_match_lo, hit_match_lo, inactive_stream_lo, empty_stream_lo;

  logic [stream_idx_width_lp-1:0] match_idx, alloc_idx, issue_idx;
  logic match_found, alloc_found, issue_found;

  logic [stream_idx_width_lp-1:0] prefetch_stream_n, prefetch_stream_r, replace_ptr_n, replace_ptr_r;

  assign prefetch_addr_o = prefetch_addr_r[prefetch_stream_r];
  assign prefetch_v_o    = prefetch_v_r;

  always_comb begin
    prefetch_v_n            = prefetch_v_r;
    prefetch_addr_n         = prefetch_addr_r;
    prefetch_stream_n       = prefetch_stream_r;
    replace_ptr_n           = replace_ptr_r;

    hit_v_n                 = req_v_i & hit_i;
    miss_v_n                = req_v_i & miss_i;
    miss_addr_n             = miss_addr_r;
    hit_addr_n              = hit_addr_r;

    match_idx               = '0;
    alloc_idx               = '0;
    issue_idx               = '0;
    match_found             = 1'b0;
    alloc_found             = 1'b0;
    issue_found             = 1'b0;

    // Initially next states are just the current state, then conditionally updated below
    for (int i = 0; i < streams_p; i++) begin
      stream_active_n[i] = stream_active_r[i];
      remaining_prefetches_n[i] = remaining_prefetches_r[i];
      expected_miss_addr_n[i] = expected_miss_addr_r[i];
      expected_hit_addr_n[i] = expected_hit_addr_r[i];
      count_n[i] = count_r[i];
    end

    if (req_v_i & miss_i) begin
      miss_addr_n      = req_addr_i;
    end else if (req_v_i & hit_i) begin
      hit_addr_n = req_addr_i;
    end

    for (int i = 0; i < streams_p; i++) begin
      miss_match_lo[i] = miss_v_r && (miss_addr_r == expected_miss_addr_r[i]);
      hit_match_lo[i]  = hit_v_r && (hit_addr_r == expected_hit_addr_r[i]) && stream_active_r[i];
      inactive_stream_lo[i] = !stream_active_r[i] && (count_r[i] > '0); // inactive but has training history, decent candidate for allocation
      empty_stream_lo[i] = !stream_active_r[i] && (count_r[i] == '0); // empty stream with no training history, ideal for allocation
    end

    // miss_v_r and hit_v_r are mutually exclusive so match logic only needs to check if either one is true
    for (int i = 0; i < streams_p; i++) begin
      if ((miss_match_lo[i] || hit_match_lo[i]) && !match_found) begin
        match_idx = i[stream_idx_width_lp-1:0];
        match_found = 1'b1;
      end
      if (empty_stream_lo[i] && !alloc_found) begin
        alloc_idx = i[stream_idx_width_lp-1:0];
        alloc_found = 1'b1;
      end
      if (inactive_stream_lo[i] && !alloc_found) begin
        alloc_idx = i[stream_idx_width_lp-1:0];
        alloc_found = 1'b1;
      end
    end

    // Advance currently-issued prefetch stream when accepted
    if (prefetch_yumi_i) begin
      prefetch_addr_n[prefetch_stream_r]      = prefetch_addr_r[prefetch_stream_r] + line_size_lp;
      expected_miss_addr_n[prefetch_stream_r] = expected_miss_addr_r[prefetch_stream_r] + line_size_lp;
      if (remaining_prefetches_r[prefetch_stream_r] == '0) begin
        prefetch_v_n = 1'b0;
      end
      else begin
        remaining_prefetches_n[prefetch_stream_r] = remaining_prefetches_r[prefetch_stream_r] - 1'b1;
      end
    end

    if (miss_v_r) begin
      if (match_found) begin
        if (count_r[match_idx] >= miss_count) begin
          remaining_prefetches_n[match_idx] = lookahead_depth;
          prefetch_addr_n[match_idx]        = miss_addr_r + line_size_lp;
          expected_miss_addr_n[match_idx]   = miss_addr_r + line_size_lp;
          expected_hit_addr_n[match_idx]    = miss_addr_r + line_size_lp;
          stream_active_n[match_idx]        = 1'b1;
          issue_found = 1'b1;
          issue_idx = match_idx;
        end else begin
          stream_active_n[match_idx]        = 1'b0;
          expected_miss_addr_n[match_idx] = miss_addr_r + line_size_lp;
          count_n[match_idx]              = count_r[match_idx] + 1'b1;
        end
      end else if (alloc_found) begin
        stream_active_n[alloc_idx] = 1'b0;
        remaining_prefetches_n[alloc_idx] = '0;
        expected_miss_addr_n[alloc_idx] = miss_addr_r + line_size_lp;
        count_n[alloc_idx] = 1'b1;
      end else begin
        stream_active_n[replace_ptr_r] = 1'b0;
        remaining_prefetches_n[replace_ptr_r] = '0;
        expected_miss_addr_n[replace_ptr_r] = miss_addr_r + line_size_lp;
        expected_hit_addr_n[replace_ptr_r] = miss_addr_r + line_size_lp;
        count_n[replace_ptr_r] = 1'b1;
        if (replace_ptr_r == streams_p-1)
          replace_ptr_n = '0;
        else
          replace_ptr_n = replace_ptr_r + 1'b1;
      end
    end else if (hit_v_r) begin
      if (match_found && !issue_found) begin
        expected_hit_addr_n[match_idx] = hit_addr_r + line_size_lp;
        issue_found = 1'b1;
        issue_idx = match_idx;
      end
    end

    for (int i = 0; i < streams_p; i++) begin
      if (!issue_found && stream_active_r[i] && (remaining_prefetches_r[i] != '0)) begin
        issue_idx = i[stream_idx_width_lp-1:0];
        issue_found = 1'b1;
      end
    end

    if (issue_found) begin
      prefetch_stream_n = issue_idx;
      prefetch_v_n = 1'b1;
    end
  end

  always_ff @(posedge clk_i) begin
    if (reset_i) begin
      prefetch_v_r           <= 1'b0;
      prefetch_stream_r      <= '0;
      replace_ptr_r          <= '0;

      miss_v_r               <= 1'b0;
      miss_addr_r            <= '0;
      hit_v_r                <= 1'b0;
      hit_addr_r             <= '0;
      for (int i = 0; i < streams_p; i++) begin
        prefetch_addr_r[i] <= '0;
        count_r[i] <= '0;
        stream_active_r[i] <= 1'b0;
        remaining_prefetches_r[i] <= '0;
        expected_miss_addr_r[i] <= '0;
        expected_hit_addr_r[i] <= '0;
      end
    end
    else begin
      prefetch_v_r           <= prefetch_v_n;
      prefetch_stream_r      <= prefetch_stream_n;
      replace_ptr_r          <= replace_ptr_n;

      miss_v_r               <= miss_v_n;
      miss_addr_r            <= miss_addr_n;
      hit_v_r                <= hit_v_n;
      hit_addr_r             <= hit_addr_n;
      for (int i = 0; i < streams_p; i++) begin
        prefetch_addr_r[i] <= prefetch_addr_n[i];
        count_r[i] <= count_n[i];
        stream_active_r[i] <= stream_active_n[i];
        remaining_prefetches_r[i] <= remaining_prefetches_n[i];
        expected_miss_addr_r[i] <= expected_miss_addr_n[i];
        expected_hit_addr_r[i] <= expected_hit_addr_n[i];
      end

`ifndef SYNTHESIS
  for (int i = 0; i < streams_p; i++) begin
    if (miss_match_lo[i]) begin
      $display("[PREF-MISS-MATCH] t=%0t stream=%0d miss=%h exp_miss=%h exp_hit=%h cnt=%0d active=%0b rem=%0d paddr=%h",
              $time, i, miss_addr_r, expected_miss_addr_r[i], expected_hit_addr_r[i],
              count_r[i], stream_active_r[i], remaining_prefetches_r[i], prefetch_addr_r[i]);
    end
    if (hit_match_lo[i]) begin
      $display("[PREF-HIT-MATCH] t=%0t stream=%0d hit=%h exp_hit=%h exp_miss=%h cnt=%0d active=%0b rem=%0d paddr=%h",
              $time, i, hit_addr_r, expected_hit_addr_r[i], expected_miss_addr_r[i],
              count_r[i], stream_active_r[i], remaining_prefetches_r[i], prefetch_addr_r[i]);
    end
  end

  if (miss_v_r && !match_found) begin
    $display("[PREF-MISS-NOMATCH] t=%0t miss=%h alloc_found=%0b alloc_idx=%0d replace_ptr=%0d",
            $time, miss_addr_r, alloc_found, alloc_idx, replace_ptr_r);
  end

  if (hit_v_r && !match_found) begin
    $display("[PREF-HIT-NOMATCH] t=%0t hit=%h", $time, hit_addr_r);
  end

  if (issue_found) begin
    $display("[PREF-ISSUE] t=%0t stream=%0d addr=%h rem=%0d",
            $time, issue_idx, prefetch_addr_n[issue_idx], remaining_prefetches_n[issue_idx]);
  end

  if (prefetch_yumi_i) begin
    $display("[PREF-YUMI] t=%0t stream=%0d addr=%h rem_before=%0d",
            $time, prefetch_stream_r, prefetch_addr_r[prefetch_stream_r],
            remaining_prefetches_r[prefetch_stream_r]);
  end
`endif

    end
  end

endmodule