#include <kernels/ncnn-meta/kernels.h>

#include <fstream>
#include <sstream>
#include <stdio.h>
#include <string>

#include <kernels/allocator.h>
#include <kernels/registry.h>
#include <tensor.h>

#define STRINGIFY(x) STRINGIFY_(x)
#define STRINGIFY_(x) #x

namespace rwkv {
namespace cpu {
Tensor cast_dtype(const Tensor &x, DType dtype);
}
namespace ncnnmeta {

int unique_layer_id() {
  static int _unique_id = 0;
  return _unique_id++;
}

int add_and_get_blob_num(int num) {
  static int _blob_num = 0;
  _blob_num += num;
  return _blob_num;
}

FILE *bp, *pp;
std::string _pp_path;

void init(const std::string &bp_path, const std::string &pp_path) {
  bp = fopen(bp_path.c_str(), "wb");
  pp = fopen(pp_path.c_str(), "wb");
  _pp_path = pp_path;
}

void destroy() {
  fclose(bp);
  fclose(pp);
  std::ifstream t(_pp_path);
  std::stringstream buffer;
  buffer << t.rdbuf();
  t.close();
  std::string pp_str = buffer.str();
  int layer_num = unique_layer_id();
  int blob_num = add_and_get_blob_num(0);
  pp_str = "7767517\n" + std::to_string(layer_num) + " " +
           std::to_string(blob_num) + "\n" + pp_str;
  std::ofstream out(_pp_path);
  out << pp_str;
  out.close();
}

void append_data_to_bin_file(const Tensor &tensor, bool write_tag) {
  RV_CHECK(tensor.device() == Device::kCPU);
  // RV_CHECK(tensor.is_constant);
  if (write_tag) {
    if (tensor.dtype() == DType::kFloat16) {
      unsigned int fp16_flag = 0x01306B47;
      fwrite((const char *)&fp16_flag, sizeof(fp16_flag), 1, bp);
    } else {
      RV_CHECK(tensor.dtype() == DType::kFloat32);
      unsigned int fp32_flag = 0;
      fwrite((const char *)&fp32_flag, sizeof(fp32_flag), 1, bp);
    }
  }
  fwrite(tensor.data_ptr(), tensor.elem_size(), tensor.numel(), bp);
}

#define PRINT_OP_TYPE_AND_NAME(op_type, input_num, output_num)                 \
  fprintf(pp, "%-16s", op_type);                                               \
  {                                                                            \
    std::string tmp = std::to_string(unique_layer_id());                       \
    fprintf(pp, " %-24s", tmp.c_str());                                        \
  }                                                                            \
  add_and_get_blob_num(output_num);                                            \
  fprintf(pp, " %d %d", input_num, output_num);

Tensor add_input(const Shape &shape, const std::string &name) {
  PRINT_OP_TYPE_AND_NAME("Input", 0, 1);
  auto output = Tensor::Empty(shape, DType::kFloat32, Device::kNCNNMeta);
  output.name = name;
  fprintf(pp, " %s", output.name.c_str());
  if (shape.size() == 4) {
    fprintf(pp, " 0=%d", (int)shape[3]);
    fprintf(pp, " 1=%d", (int)shape[2]);
    fprintf(pp, " 2=%d", (int)shape[1]);
    fprintf(pp, " 3=%d", (int)shape[0]);
  } else if (shape.size() == 3) {
    fprintf(pp, " 0=%d", (int)shape[2]);
    fprintf(pp, " 1=%d", (int)shape[1]);
    fprintf(pp, " 2=%d", (int)shape[0]);
  } else if (shape.size() == 2) {
    fprintf(pp, " 0=%d", (int)shape[1]);
    fprintf(pp, " 1=%d", (int)shape[0]);
  } else if (shape.size() == 1) {
    fprintf(pp, " 0=%d", (int)shape[0]);
  } else {
    RV_UNIMPLEMENTED();
  }
  fprintf(pp, "\n");
  return output;
}

Tensor layernorm(const Tensor &x, const Tensor &weight, const Tensor &bias) {
  PRINT_OP_TYPE_AND_NAME("LayerNorm", 1, 1);
  auto output = Tensor::Empty(x.shape(), DType::kFloat32, Device::kNCNNMeta);
  fprintf(pp, " %s %s", x.name.c_str(), output.name.c_str());

  fprintf(pp, " 0=%d", static_cast<int>(weight.numel()));
  fprintf(pp, " 1=%e", 1e-5f);
  fprintf(pp, " 2=1");
  fprintf(pp, "\n");
  append_data_to_bin_file(cpu::cast_dtype(weight, DType::kFloat32), false);
  append_data_to_bin_file(cpu::cast_dtype(bias, DType::kFloat32), false);
  return output;
}

Tensor matmul(const Tensor &a, const Tensor &b) {
  RV_CHECK(a.device() == Device::kNCNNMeta);
  auto [a_reshape, reshaped] = [&]() -> std::pair<Tensor, bool> {
    if (a.shape().size() == 1) {
      PRINT_OP_TYPE_AND_NAME("Reshape", 1, 1);
      auto output =
          Tensor::Empty({1, a.shape()[0]}, DType::kFloat32, Device::kNCNNMeta);
      fprintf(pp, " %s %s", a.name.c_str(), output.name.c_str());
      fprintf(pp, " 0=0 1=1\n");
      return {output, true};
    }
    return {a, false};
  }();
  int constantM = 0;
  int constantN = 0;
  int constantK = 0;
  RV_CHECK(a_reshape.shape().size() == 2);
  // if (a.device() == Device::kCPU) {
  //   append_data_to_bin_file(a, true);
  //   constantM = a.shape()[0];
  //   constantK = a.shape()[1];
  // }
  RV_CHECK(b.shape().size() == 2);
  if (b.device() == Device::kCPU) {
    append_data_to_bin_file(cpu::cast_dtype(b, DType::kFloat16), true);
    constantK = b.shape()[0];
    constantN = b.shape()[1];
  }
  auto output = Tensor::Empty({a_reshape.shape()[0], b.shape()[1]},
                              DType::kFloat32, Device::kNCNNMeta);
  int input_num = 0;
  if (a_reshape.device() == Device::kNCNNMeta) {
    input_num++;
  }
  if (b.device() == Device::kNCNNMeta) {
    input_num++;
  }
  PRINT_OP_TYPE_AND_NAME("Gemm", input_num, 1);
  if (a_reshape.device() == Device::kNCNNMeta) {
    fprintf(pp, " %s", a_reshape.name.c_str());
  }
  if (b.device() == Device::kNCNNMeta) {
    fprintf(pp, " %s", b.name.c_str());
  }
  fprintf(pp, " %s", output.name.c_str());
  fprintf(pp, " 4=%d 5=%d 7=%d 8=%d 9=%d", a_reshape.device() == Device::kCPU,
          b.device() == Device::kCPU, constantM, constantN, constantK);
  fprintf(pp, "\n");
  if (reshaped) {
    PRINT_OP_TYPE_AND_NAME("Reshape", 1, 1);
    auto squeezed =
        Tensor::Empty({b.shape()[1]}, DType::kFloat32, Device::kNCNNMeta);
    fprintf(pp, " %s %s", output.name.c_str(), squeezed.name.c_str());
    fprintf(pp, " 0=-1\n");
    return squeezed;
  } else {
    return output;
  }
}

Tensor MemoryData(const Tensor &x) {
  RV_CHECK(x.device() == Device::kCPU);
  PRINT_OP_TYPE_AND_NAME("MemoryData", 0, 1);
  auto output = Tensor::Empty(x.shape(), DType::kFloat32, Device::kNCNNMeta);
  // use x's name
  output.name = x.name;
  fprintf(pp, " %s", output.name.c_str());
  if (x.shape().size() == 2) {
    fprintf(pp, " 0=%d", (int)x.shape()[1]);
    fprintf(pp, " 1=%d", (int)x.shape()[0]);
  } else if (x.shape().size() == 1) {
    fprintf(pp, " 0=%d", (int)x.shape()[0]);
  } else {
    RV_UNIMPLEMENTED();
  }
  fprintf(pp, "\n");
  append_data_to_bin_file(cpu::cast_dtype(x, DType::kFloat32), false);
  return output;
}

std::map<std::string, int> binary_op_ids{{"add", 0},     {"sub", 1},
                                         {"mul", 2},     {"div", 3},
                                         {"maximum", 4}, {"rsub", 7}};

// TODO: shape inference
#define BINARYOP(op_type_name)                                                 \
  Tensor op_type_name(const Tensor &x, const Tensor &y) {                      \
    Tensor meta_x = x.device() == Device::kCPU ? MemoryData(x) : x;            \
    Tensor meta_y = y.device() == Device::kCPU ? MemoryData(y) : y;            \
    PRINT_OP_TYPE_AND_NAME("BinaryOp", 2, 1);                                  \
    auto output =                                                              \
        Tensor::Empty(Shape(std::max(x.shape().size(), y.shape().size()), 0),  \
                      DType::kFloat32, Device::kNCNNMeta);                     \
    fprintf(pp, " %s", meta_x.name.c_str());                                   \
    fprintf(pp, " %s", meta_y.name.c_str());                                   \
    fprintf(pp, " %s", output.name.c_str());                                   \
    fprintf(pp, " 0=%d", binary_op_ids[STRINGIFY(op_type_name)]);              \
    fprintf(pp, "\n");                                                         \
    return output;                                                             \
  }

BINARYOP(add);
BINARYOP(sub);
BINARYOP(mul);
BINARYOP(div);
BINARYOP(maximum);

Tensor rsub_scalar(float x, const Tensor &y) {
  Tensor meta_y = y.device() == Device::kCPU ? MemoryData(y) : y;
  PRINT_OP_TYPE_AND_NAME("BinaryOp", 1, 1);
  auto output = Tensor::Empty({}, DType::kFloat32, Device::kNCNNMeta);
  fprintf(pp, " %s", meta_y.name.c_str());
  fprintf(pp, " %s", output.name.c_str());
  fprintf(pp, " 0=%d", binary_op_ids["rsub"]);
  fprintf(pp, " 1=1");
  fprintf(pp, " 2=%e", x);
  fprintf(pp, "\n");
  return output;
}

Tensor exp(const Tensor &x) {
  PRINT_OP_TYPE_AND_NAME("Exp", 1, 1);
  auto output = Tensor::Empty(x.shape(), DType::kFloat32, Device::kNCNNMeta);
  fprintf(pp, " %s", x.name.c_str());
  fprintf(pp, " %s", output.name.c_str());
  fprintf(pp, "\n");
  return output;
}

Tensor relu(const Tensor &x) {
  PRINT_OP_TYPE_AND_NAME("ReLU", 1, 1);
  auto output = Tensor::Empty(x.shape(), DType::kFloat32, Device::kNCNNMeta);
  fprintf(pp, " %s", x.name.c_str());
  fprintf(pp, " %s", output.name.c_str());
  fprintf(pp, "\n");
  return output;
}

Tensor sigmoid(const Tensor &x) {
  PRINT_OP_TYPE_AND_NAME("Sigmoid", 1, 1);
  auto output = Tensor::Empty(x.shape(), DType::kFloat32, Device::kNCNNMeta);
  fprintf(pp, " %s", x.name.c_str());
  fprintf(pp, " %s", output.name.c_str());
  fprintf(pp, "\n");
  return output;
}

Tensor mark_as_output(const Tensor &x, const std::string& name) {
  PRINT_OP_TYPE_AND_NAME("Split", 1, 1);
  auto output =
      Tensor::Empty(x.shape(), DType::kFloat32, Device::kNCNNMeta);
  output.name = name;
  fprintf(pp, " %s", x.name.c_str());
  fprintf(pp, " %s", output.name.c_str());
  fprintf(pp, "\n");
  return output;
}

std::pair<Tensor, Tensor> split2(const Tensor &x) {
  Tensor meta_x = x.device() == Device::kCPU ? MemoryData(x) : x;
  PRINT_OP_TYPE_AND_NAME("Split", 1, 2);
  auto output1 =
      Tensor::Empty(meta_x.shape(), DType::kFloat32, Device::kNCNNMeta);
  auto output2 =
      Tensor::Empty(meta_x.shape(), DType::kFloat32, Device::kNCNNMeta);
  fprintf(pp, " %s", meta_x.name.c_str());
  fprintf(pp, " %s", output1.name.c_str());
  fprintf(pp, " %s", output2.name.c_str());
  fprintf(pp, "\n");
  return {output1, output2};
}

std::tuple<Tensor, Tensor, Tensor> split3(const Tensor &x) {
  Tensor meta_x = x.device() == Device::kCPU ? MemoryData(x) : x;
  PRINT_OP_TYPE_AND_NAME("Split", 1, 3);
  auto output1 = Tensor::Empty(x.shape(), DType::kFloat32, Device::kNCNNMeta);
  auto output2 = Tensor::Empty(x.shape(), DType::kFloat32, Device::kNCNNMeta);
  auto output3 = Tensor::Empty(x.shape(), DType::kFloat32, Device::kNCNNMeta);
  fprintf(pp, " %s", meta_x.name.c_str());
  fprintf(pp, " %s", output1.name.c_str());
  fprintf(pp, " %s", output2.name.c_str());
  fprintf(pp, " %s", output3.name.c_str());
  fprintf(pp, "\n");
  return {output1, output2, output3};
}

std::tuple<Tensor, Tensor, Tensor, Tensor> split4(const Tensor &x) {
  Tensor meta_x = x.device() == Device::kCPU ? MemoryData(x) : x;
  PRINT_OP_TYPE_AND_NAME("Split", 1, 4);
  auto output1 = Tensor::Empty(x.shape(), DType::kFloat32, Device::kNCNNMeta);
  auto output2 = Tensor::Empty(x.shape(), DType::kFloat32, Device::kNCNNMeta);
  auto output3 = Tensor::Empty(x.shape(), DType::kFloat32, Device::kNCNNMeta);
  auto output4 = Tensor::Empty(x.shape(), DType::kFloat32, Device::kNCNNMeta);
  fprintf(pp, " %s", meta_x.name.c_str());
  fprintf(pp, " %s", output1.name.c_str());
  fprintf(pp, " %s", output2.name.c_str());
  fprintf(pp, " %s", output3.name.c_str());
  fprintf(pp, " %s", output4.name.c_str());
  fprintf(pp, "\n");
  return {output1, output2, output3, output4};
}

std::tuple<Tensor, Tensor, Tensor, Tensor, Tensor>
att(const Tensor &x, const Tensor &sx, const Tensor &aa, const Tensor &bb,
    const Tensor &pp, const Tensor &ln_w, const Tensor &ln_b,
    const Tensor &k_mix, const Tensor &v_mix, const Tensor &r_mix,
    const Tensor &t_decay, const Tensor &t_first, const Tensor &kw,
    const Tensor &vw, const Tensor &rw, const Tensor &ow) {
  auto [x_s1, x_s2] = split2(x);
  auto xx = layernorm(x_s1, ln_w, ln_b);
  auto [xx_s1, xx_s2, xx_s3, xx_s4] = split4(xx);
  // auto [kx, vx, rx] = time_mix()
  auto [sx_s1, sx_s2, sx_s3] = split3(sx);
  auto [k_mix_s1, k_mix_s2] = split2(k_mix);
  auto [v_mix_s1, v_mix_s2] = split2(v_mix);
  auto [r_mix_s1, r_mix_s2] = split2(r_mix);
  auto kx = xx_s1 * k_mix_s1 + sx_s1 * (1 - k_mix_s2);
  auto vx = xx_s2 * v_mix_s1 + sx_s2 * (1 - v_mix_s2);
  auto rx = xx_s3 * r_mix_s1 + sx_s3 * (1 - r_mix_s2);

  auto r = sigmoid(matmul(rx, rw));
  auto k = matmul(kx, kw);
  auto [k_s1, k_s2, k_s3] = split3(k);
  auto v = matmul(vx, vw);
  auto [v_s1, v_s2] = split2(v);

  auto ww = t_first + k_s1;
  auto [ww_s1, ww_s2] = split2(ww);
  auto [pp_s1, pp_s2, pp_s3] = split3(pp);
  auto p = maximum(pp_s1, ww_s1);
  auto [p_s1, p_s2] = split2(p);
  auto e1 = exp(pp_s2 - p_s1);
  auto [e1_s1, e1_s2] = split2(e1);
  auto e2 = exp(ww_s2 - p_s2);
  auto [e2_s1, e2_s2] = split2(e2);
  auto [aa_s1, aa_s2] = split2(aa);
  auto [bb_s1, bb_s2] = split2(bb);
  auto wkv = ((e1_s1 * aa_s1 + e2_s1 * v_s1) / (e1_s2 * bb_s1 + e2_s2));
  // if (wkv->dtype() == DType::kFloat16) ...
  auto ww2 = t_decay + pp_s3;
  auto [ww2_s1, ww2_s2] = split2(ww2);
  auto p2 = maximum(ww2_s1, k_s2);
  auto [p2_s1, p2_s2, p2_s3] = split3(p2);
  auto e1n = exp(ww2_s2 - p2_s1);
  auto [e1n_s1, e1n_s2] = split2(e1n);
  auto e2n = exp(k_s3 - p2_s2);
  auto [e2n_s1, e2n_s2] = split2(e2n);

  auto out = matmul(r * wkv, ow);
  return {x_s2 + out, xx_s4, e1n_s1 * aa_s2 + e2n_s1 * v_s2,
          e1n_s2 * bb_s2 + e2n_s2, p2_s3};
}

KernelRegister att_reg("att", Device::kNCNNMeta, att);

std::tuple<Tensor, Tensor> ffn(const Tensor &x, const Tensor &sx,
                               const Tensor &ln_w, const Tensor &ln_b,
                               const Tensor &k_mix, const Tensor &r_mix,
                               const Tensor &kw, const Tensor &vw,
                               const Tensor &rw) {
  auto [x_s1, x_s2] = split2(x);
  auto xx = layernorm(x_s1, ln_w, ln_b);
  auto [xx_s1, xx_s2, xx_s3] = split3(xx);
  auto [sx_s1, sx_s2] = split2(sx);
  auto [k_mix_s1, k_mix_s2] = split2(k_mix);
  auto [r_mix_s1, r_mix_s2] = split2(r_mix);
  // auto [kx, rx] = channel_mix(xx, sx, k_mix, r_mix);
  auto kx = xx_s1 * k_mix_s1 + sx_s1 * (1 - k_mix_s2);
  auto rx = xx_s2 * r_mix_s1 + sx_s2 * (1 - r_mix_s2);

  auto r = sigmoid(matmul(rx, rw));
  auto vx = relu(matmul(kx, kw));
  vx = vx * vx;
  auto out = r * matmul(vx, vw);
  return {x_s2 + out, xx_s3};
}

KernelRegister ffn_reg("ffn", Device::kNCNNMeta, ffn);

class NullAllocator : public rwkv::Allocator {
public:
  void *DoAllocate(size_t size) { return nullptr; }
  void Deallocate(void *ptr) {}
};

rwkv::Allocator &allocator() {
  static NullAllocator allocator;
  return allocator;
}

KernelRegister allocator_reg("allocator", Device::kNCNNMeta, allocator);

KernelRegister layernorm_reg("layernorm", Device::kNCNNMeta, layernorm);
KernelRegister matmul_reg("matmul", Device::kNCNNMeta, matmul);
KernelRegister add_reg("add", Device::kNCNNMeta, add);
KernelRegister sub_reg("sub", Device::kNCNNMeta, sub);
KernelRegister mul_reg("mul", Device::kNCNNMeta, mul);
KernelRegister div_reg("div", Device::kNCNNMeta, div);
KernelRegister maximum_reg("maximum", Device::kNCNNMeta, maximum);
KernelRegister rsub_reg("rsub_scalar", Device::kNCNNMeta, rsub_scalar);
KernelRegister exp_reg("exp", Device::kNCNNMeta, exp);
KernelRegister relu_reg("relu", Device::kNCNNMeta, relu);
KernelRegister sigmoid_reg("sigmoid", Device::kNCNNMeta, sigmoid);
KernelRegister mark_as_output_reg("mark_as_output", Device::kNCNNMeta, mark_as_output);

} // namespace ncnnmeta
} // namespace rwkv
