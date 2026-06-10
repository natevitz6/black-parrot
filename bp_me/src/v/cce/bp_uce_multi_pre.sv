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
    , parameter `BSG_INV_PARAM(l2_block_width_p)
    , parameter train_cnt_p = "inv"
    , parameter lookahead_depth_p = "inv"
    , parameter idle_threshold_p = "inv"
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
  
  localparam int stream_idx_width_lp = `BSG_SAFE_CLOG2(streams_p);
  localparam int block_bytes_lp = l2_block_width_p / 8;
  localparam int block_offset_width_lp = `BSG_SAFE_CLOG2(block_bytes_lp);
  localparam logic [addr_width_p-1:0] line_size_lp = addr_width_p'(block_bytes_lp);

  logic prefetch_v_r, prefetch_v_n;
  logic prefetch_cacheable_lo;

  logic [streams_p-1:0] stream_active_r, stream_active_n;
  logic [streams_p-1:0][`BSG_SAFE_CLOG2(lookahead_depth_p+1)-1:0] remaining_prefetches_r, remaining_prefetches_n;
  logic [streams_p-1:0][`BSG_SAFE_CLOG2(train_cnt_p+1)-1:0] train_cnt_r, train_cnt_n;
  logic [streams_p-1:0][`BSG_SAFE_CLOG2(idle_threshold_p+1)-1:0] idle_cnt_r, idle_cnt_n;
  logic [streams_p-1:0][addr_width_p-1:0] prefetch_addr_r, prefetch_addr_n;

  // Expected demand-miss and demand-hit addresses for each stream.
  // expected_hit_addr_r forms the lower bound of the accepted hit window;
  // prefetch_addr_r tracks the current upper bound.
  logic [streams_p-1:0][addr_width_p-1:0] expected_miss_addr_r, expected_miss_addr_n;
  logic [streams_p-1:0][addr_width_p-1:0] expected_hit_addr_r, expected_hit_addr_n;

  // Registered miss and hit observation stage
  logic miss_v_r, miss_v_n, hit_v_r, hit_v_n;
  logic [addr_width_p-1:0] miss_addr_r, miss_addr_n, hit_addr_n, hit_addr_r;
  logic [streams_p-1:0] miss_match_lo, hit_match_lo, inactive_stream_lo, empty_stream_lo;
  logic [stream_idx_width_lp-1:0] match_stream_idx, alloc_stream_idx, issue_stream_idx, idle_stream_idx, empty_stream_idx, inactive_stream_idx;
  logic match_stream_found, issue_stream_found, idle_stream_found, empty_stream_found, inactive_stream_found;
  logic [stream_idx_width_lp-1:0] prefetch_stream_idx_n, prefetch_stream_idx_r, replace_stream_idx_n, replace_stream_idx_r;

  logic last_req_block_v_r, last_req_block_v_n;
  logic [addr_width_p-1:0] last_req_block_addr_r, last_req_block_addr_n;
  logic train_req_v_lo;
  logic [addr_width_p-1:0] req_block_addr_lo;

  assign req_block_addr_lo = {req_addr_i[addr_width_p-1:block_offset_width_lp], {block_offset_width_lp{1'b0}}};
  assign train_req_v_lo = req_v_i && (miss_i || hit_i) && (!last_req_block_v_r || (req_block_addr_lo != last_req_block_addr_r));

  assign prefetch_addr_o = prefetch_addr_r[prefetch_stream_idx_r];
  assign prefetch_v_o    = prefetch_v_r;

  always_comb begin
    // Default next-state assignments.
    // Prefetcher outputs default to previous values to keep state if the UCE is not ready
    prefetch_v_n            = prefetch_v_r;
    prefetch_stream_idx_n   = prefetch_stream_idx_r;
    replace_stream_idx_n    = replace_stream_idx_r;

    match_stream_idx               = '0;
    alloc_stream_idx               = '0;
    issue_stream_idx               = '0;
    idle_stream_idx                = '0;
    empty_stream_idx               = '0;
    inactive_stream_idx            = '0;
    match_stream_found             = 1'b0;
    issue_stream_found             = 1'b0;
    idle_stream_found              = 1'b0;
    empty_stream_found             = 1'b0;
    inactive_stream_found          = 1'b0;

    for (int i = 0; i < streams_p; i++) begin
      prefetch_addr_n[i] = prefetch_addr_r[i];
      stream_active_n[i] = stream_active_r[i];
      remaining_prefetches_n[i] = remaining_prefetches_r[i];
      expected_miss_addr_n[i] = expected_miss_addr_r[i];
      expected_hit_addr_n[i] = expected_hit_addr_r[i];
      train_cnt_n[i] = train_cnt_r[i];
      idle_cnt_n[i] = idle_cnt_r[i];
    end

    // Update miss and hit registers with current cycle's inputs
    hit_v_n                 = train_req_v_lo & hit_i;
    miss_v_n                = train_req_v_lo & miss_i;
    miss_addr_n             = miss_addr_r;
    hit_addr_n              = hit_addr_r;

    if (train_req_v_lo) begin
      last_req_block_v_n = 1'b1;
      last_req_block_addr_n = req_block_addr_lo;
    end else begin
      last_req_block_v_n = last_req_block_v_r;
      last_req_block_addr_n = last_req_block_addr_r;
    end

    if (train_req_v_lo & miss_i) begin
      miss_addr_n = req_block_addr_lo;
    end else if (train_req_v_lo & hit_i) begin
      hit_addr_n = req_block_addr_lo;
    end

    // Classify each stream against the registered demand access and update recency.
    for (int i = 0; i < streams_p; i++) begin
      miss_match_lo[i] = miss_v_r && (miss_addr_r == expected_miss_addr_r[i]);
      hit_match_lo[i]  = hit_v_r && (hit_addr_r >= expected_hit_addr_r[i]) && (hit_addr_r <= prefetch_addr_r[i]) && stream_active_r[i];
      inactive_stream_lo[i] = !stream_active_r[i] && (train_cnt_r[i] > '0); // inactive but has training history, decent candidate for allocation
      empty_stream_lo[i] = !stream_active_r[i] && (train_cnt_r[i] == '0); // empty stream with no training history, ideal for allocation
      // Age all stream entries, active or inactive, based on how recently they matched
      // This lets replacement prefer recently useful trained entries over colder ones
      if ((miss_v_r || hit_v_r) && !(miss_match_lo[i] || hit_match_lo[i]) && (idle_cnt_r[i] < idle_threshold_p))
        idle_cnt_n[i] = idle_cnt_r[i] + 1'b1;
    end

    // Resolve highest-priority candidate streams for matching and allocation.
    // Allocation priority is match > empty > idle > inactive.
    for (int i = 0; i < streams_p; i++) begin
      if ((miss_match_lo[i] || hit_match_lo[i]) && !match_stream_found) begin
        match_stream_idx = i[stream_idx_width_lp-1:0];
        match_stream_found = 1'b1;
      end
      if (empty_stream_lo[i] && !empty_stream_found) begin
        empty_stream_idx = i[stream_idx_width_lp-1:0];
        empty_stream_found = 1'b1;
      end
      if ((idle_cnt_r[i] >= idle_threshold_p) && !idle_stream_found) begin
        idle_stream_idx = i[stream_idx_width_lp-1:0];
        idle_stream_found = 1'b1;
      end
      if (inactive_stream_lo[i] && !inactive_stream_found) begin
        inactive_stream_idx = i[stream_idx_width_lp-1:0];
        inactive_stream_found = 1'b1;
      end
    end

    if (empty_stream_found) begin
      alloc_stream_idx = empty_stream_idx;
    end else if (idle_stream_found) begin
      alloc_stream_idx = idle_stream_idx;
    end else if (inactive_stream_found) begin
      alloc_stream_idx = inactive_stream_idx;
    end

    // Advance currently-issued prefetch stream when accepted
    if (prefetch_yumi_i) begin
      prefetch_addr_n[prefetch_stream_idx_r]      = prefetch_addr_r[prefetch_stream_idx_r] + line_size_lp;
      expected_miss_addr_n[prefetch_stream_idx_r] = expected_miss_addr_r[prefetch_stream_idx_r] + line_size_lp;
      if (remaining_prefetches_r[prefetch_stream_idx_r] == '0) begin
        prefetch_v_n = 1'b0;
      end
      else begin
        remaining_prefetches_n[prefetch_stream_idx_r] = remaining_prefetches_r[prefetch_stream_idx_r] - 1'b1;
      end
    end

    // Update stream training and state from the registered demand access.
    if (miss_v_r) begin
      if (match_stream_found) begin
        if (train_cnt_r[match_stream_idx] >= train_cnt_p) begin
          remaining_prefetches_n[match_stream_idx] = lookahead_depth_p;
          prefetch_addr_n[match_stream_idx]        = miss_addr_r + line_size_lp;
          expected_miss_addr_n[match_stream_idx]   = miss_addr_r + line_size_lp;
          expected_hit_addr_n[match_stream_idx]    = miss_addr_r + line_size_lp;
          stream_active_n[match_stream_idx]        = 1'b1;
          issue_stream_found = 1'b1;
          issue_stream_idx = match_stream_idx;
          idle_cnt_n[match_stream_idx] = '0;
        end else begin
          stream_active_n[match_stream_idx]      = 1'b0;
          expected_miss_addr_n[match_stream_idx]   = miss_addr_r + line_size_lp;
          train_cnt_n[match_stream_idx]        = train_cnt_r[match_stream_idx] + 1'b1;
          idle_cnt_n[match_stream_idx] = '0;
        end
      end else if (empty_stream_found || inactive_stream_found || idle_stream_found) begin
        stream_active_n[alloc_stream_idx] = 1'b0;
        remaining_prefetches_n[alloc_stream_idx] = '0;
        expected_miss_addr_n[alloc_stream_idx]   = miss_addr_r + line_size_lp;
        train_cnt_n[alloc_stream_idx] = 1'b1;
        idle_cnt_n[alloc_stream_idx] = '0;
      end else begin
        stream_active_n[replace_stream_idx_r] = 1'b0;
        remaining_prefetches_n[replace_stream_idx_r] = '0;
        expected_miss_addr_n[replace_stream_idx_r]   = miss_addr_r + line_size_lp;
        train_cnt_n[replace_stream_idx_r] = 1'b1;
        idle_cnt_n[replace_stream_idx_r] = '0;
        if (replace_stream_idx_r == streams_p-1)
          replace_stream_idx_n = '0;
        else
          replace_stream_idx_n = replace_stream_idx_r + 1'b1;
      end
    end else if (hit_v_r) begin
      if (match_stream_found && !issue_stream_found) begin
        expected_hit_addr_n[match_stream_idx] = hit_addr_r + line_size_lp;
        issue_stream_found = 1'b1;
        issue_stream_idx = match_stream_idx;
        idle_cnt_n[match_stream_idx] = '0;
      end
    end
    
    // Select the next stream to issue and gate speculative requests to cacheable DRAM.
    for (int i = 0; i < streams_p; i++) begin
      if (!issue_stream_found && stream_active_r[i] && (remaining_prefetches_r[i] != '0)) begin
        issue_stream_idx = i[stream_idx_width_lp-1:0];
        issue_stream_found = 1'b1;
      end
    end

    if (issue_stream_found && prefetch_cacheable_lo) begin
      prefetch_stream_idx_n = issue_stream_idx;
      prefetch_v_n = 1'b1;
    end
  end

  // Speculative prefetches are only issued into cacheable DRAM space.
  bp_cce_pma 
    #(.bp_params_p(bp_params_p))
    pma
      (.paddr_i(prefetch_addr_n[issue_stream_idx])
      ,.cacheable_addr_o(prefetch_cacheable_lo)
      );

  always_ff @(posedge clk_i) begin
    if (reset_i) begin
      prefetch_v_r           <= 1'b0;
      prefetch_stream_idx_r  <= '0;
      replace_stream_idx_r   <= '0;

      miss_v_r               <= 1'b0;
      miss_addr_r            <= '0;
      hit_v_r                <= 1'b0;
      hit_addr_r             <= '0;

      last_req_block_v_r     <= 1'b0;
      last_req_block_addr_r  <= '0;
      for (int i = 0; i < streams_p; i++) begin
        prefetch_addr_r[i] <= '0;
        train_cnt_r[i] <= '0;
        stream_active_r[i] <= 1'b0;
        remaining_prefetches_r[i] <= '0;
        expected_miss_addr_r[i] <= '0;
        expected_hit_addr_r[i] <= '0;
        idle_cnt_r[i] <= '0;
      end
    end
    else begin
      prefetch_v_r           <= prefetch_v_n;
      prefetch_stream_idx_r  <= prefetch_stream_idx_n;
      replace_stream_idx_r   <= replace_stream_idx_n;

      miss_v_r               <= miss_v_n;
      miss_addr_r            <= miss_addr_n;
      hit_v_r                <= hit_v_n;
      hit_addr_r             <= hit_addr_n;

      last_req_block_v_r     <= last_req_block_v_n;
      last_req_block_addr_r  <= last_req_block_addr_n;
      for (int i = 0; i < streams_p; i++) begin
        prefetch_addr_r[i] <= prefetch_addr_n[i];
        train_cnt_r[i] <= train_cnt_n[i];
        stream_active_r[i] <= stream_active_n[i];
        remaining_prefetches_r[i] <= remaining_prefetches_n[i];
        expected_miss_addr_r[i] <= expected_miss_addr_n[i];
        expected_hit_addr_r[i] <= expected_hit_addr_n[i];
        idle_cnt_r[i] <= idle_cnt_n[i];
      end
    end
  end

endmodule