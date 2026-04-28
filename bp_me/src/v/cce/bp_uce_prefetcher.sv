/**
 *
 * Name:
 *   bp_uce_prefetcher.sv
 *
 * Description:
 *   This is the UCE side L2 prefetch request generator
 *
 */

`include "bp_common_defines.svh"
`include "bp_me_defines.svh"

module bp_uce_prefetcher
  import bp_common_pkg::*;
  import bp_me_pkg::*;
  #(parameter bp_params_e bp_params_p = e_bp_default_cfg
    , parameter addr_width_p = "inv"
    , parameter block_offset_width_p = "inv"
    , parameter miss_count = "inv"
    )
   (input clk_i
     , input reset_i

     , input miss_v_i
     , input [addr_width_p-1:0] miss_addr_i

     , output logic prefetch_v_o
     , output logic [addr_width_p-1:0] prefetch_addr_o
     , input prefetch_yumi_i
    );

    logic prefetch_v_r;
    logic [1:0] count_r;
    logic [addr_width_p-1:0] prefetch_addr_r;

    assign prefetch_addr_o = prefetch_addr_r;
    assign prefetch_v_o = prefetch_v_r;

    always_ff @(posedge clk_i) begin
        if (reset_i) begin
            prefetch_v_r <= 1'b0;
            prefetch_addr_r <= '0;
            count_r <= '0;
        end
        else begin
            if (prefetch_yumi_i) begin
                prefetch_v_r <= 1'b0;
            end
            if (miss_v_i) begin
                if (miss_count == 1) begin
                    prefetch_v_r <= 1'b1;
                end else if (miss_addr_i == prefetch_addr_r) begin
                        if (count_r == miss_count) begin
                            prefetch_v_r <= 1'b1;
                        end
                        else begin

                            count_r <= count_r + 2'd1;
                        end
                end else begin
                    prefetch_v_r <= 1'b1;
                    count_r <= 2'd1;
                end

                prefetch_addr_r <= miss_addr_i + (addr_width_p'(1) << block_offset_width_p);      
            end
        end
    end
endmodule

