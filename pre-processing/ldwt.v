module ldwt_block (
    input  wire         clk,
    input  wire         reset,
    input  wire signed [15:0] y_even,   // y_{2n}
    input  wire signed [15:0] y_odd,    // y_{2n+1}
    input  wire signed [15:0] y_even_next, // y_{2n+2} (for predict)
    input  wire signed [15:0] d_prev,      // d_{n1-1}
    input  wire signed [15:0] a_next,      // a_{n1+1}
    input  wire  [2:0]  sel,               // control signal: step selector S1-S4
    output reg  signed [15:0] a_n,
    output reg  signed [15:0] d_n
);

    // Fixed-point coefficients (Q1.15)
    parameter signed [15:0] C1 = 16'sd10395; // (sqrt(3)-1)/4 ≈ 0.317
    parameter signed [15:0] C2 = 16'sd14204; // sqrt(3)/4 ≈ 0.433
    parameter signed [15:0] C3 = 16'sd22338; // (sqrt(3)+1)/4 ≈ 0.683
    parameter signed [15:0] SQRT2_INV = 16'sd23170; // 1/sqrt(2) ≈ 0.707

    // Internal registers
    reg signed [31:0] d_n1, a_n1, d_n2;

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            d_n1 <= 0;
            a_n1 <= 0;
            d_n2 <= 0;
            a_n  <= 0;
            d_n  <= 0;
        end else begin
            case(sel)
                3'b001: begin
                    // Step 1: Predict d_n1
                    // d_n1 = y_odd - ((sqrt(3)-1)/4)*(y_even + y_even_next)
                    d_n1 <= y_odd - ((C1 * (y_even + y_even_next)) >>> 15);
                end

                3'b010: begin
                    // Step 2a: Update a_n1
                    // a_n1 = y_even + (sqrt(3)/4)*(d_n1 + d_prev)
                    a_n1 <= y_even + ((C2 * (d_n1 + d_prev)) >>> 15);

                    // Step 2b: Refine d_n2
                    // d_n2 = d_n1 + ((sqrt(3)+1)/4)*(a_n1 + a_next)
                    d_n2 <= d_n1 + ((C3 * (a_n1 + a_next)) >>> 15);
                end

                3'b011: begin
                    // Step 3: Scaling to get final outputs
                    // a_n = a_n1 / sqrt(2)
                    // d_n = d_n2 / sqrt(2)
                    a_n <= (a_n1 * SQRT2_INV) >>> 15;
                    d_n <= (d_n2 * SQRT2_INV) >>> 15;
                end

                default: begin
                    // Hold values
                    d_n1 <= d_n1;
                    a_n1 <= a_n1;
                    d_n2 <= d_n2;
                    a_n  <= a_n;
                    d_n  <= d_n;
                end
            endcase
        end
    end

endmodule
