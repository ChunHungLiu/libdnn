#include <rbm.h>
#include <curand.h>
#include <curand_kernel.h>
#define fill_bias(x) { fillLastColumnWith(x, 1.0f); }

ostream& operator << (ostream& os, const RBM_TYPE& type) {
  switch (type) {
    case GAUSSIAN_BERNOULLI:
      os << "Gaussian-Bernoulli RBM"; break;
    case BERNOULLI_BERNOULLI:
      os << "Bernoulli-Bernoulli RBM"; break;
  }
  return os;
}

hmat batchFeedForwarding(const hmat& X, const mat& w) {
  size_t nData = X.getCols();

  hmat Y(w.getCols(), nData);
  Batches batches(2048, nData);
  for (Batches::iterator itr = batches.begin(); itr != batches.end(); ++itr) {
    mat fin  = getBatchData(X, *itr);
    mat fout = sigmoid(fin * w);
    fill_bias(fout);

    size_t offset = fout.getCols() * itr->offset,
	   nBytes = sizeof(float) * fout.size();

    fout = ~fout;
    CCE(cudaMemcpy(Y.getData() + offset, fout.getData(), nBytes, cudaMemcpyDeviceToHost));
  }
  return Y;
}

std::vector<mat> initStackedRBM(DataSet& data, const std::vector<size_t>& dims,
    float slopeThres, RBM_TYPE type, float learning_rate) {

  std::vector<mat> weights(dims.size() - 1);

  size_t nData = data.size();

  hmat X = data.getX();
  for (size_t i=0; i<weights.size(); ++i) {
    // Only the first layer need to be Gaussian-Bernoulli
    if (type == GAUSSIAN_BERNOULLI && i > 0)
      type = BERNOULLI_BERNOULLI;

    weights[i] = rbmTrain(X, dims[i + 1], slopeThres, type, learning_rate);
    X = batchFeedForwarding(X, weights[i]);
  }

  return weights;
}

__global__ void setupCuRandState( curandState * state, unsigned long seed ) {
  int x = blockIdx.x*blockDim.x + threadIdx.x;
  curand_init ( seed, x, 0, &state[x] );
}

inline __device__ void gaussian(float& x, curandState* state) {
  x += curand_normal(state);
}

inline __device__ void bernoulli(float& x, curandState* state) {
  x = (float) (x >= curand_uniform(state));
}

typedef __device__ void (*Operation)(float&, curandState*);

template <Operation op>
__global__ void sampling_kernel(float* const data, curandState* globalState, unsigned int rows, unsigned int cols) {
  int tx = threadIdx.x;
  int ty = threadIdx.y;

  // Matrix index
  int x = blockIdx.x*blockDim.x + tx;
  int y = blockIdx.y*blockDim.y + ty;

  if (x >= cols || y >= rows)
    return;

  int i = x * rows + y;
  int j = tx * blockDim.y + ty;
  op(data[i], globalState +j);
  // data[i] = data[i] + curand_normal(globalState + j);
  __syncthreads();
}

class CURAND_STATE {
public:
  CURAND_STATE(unsigned seed = unsigned(time(NULL)), int N = 32): _states(NULL) {
    cudaMalloc ( &_states, N * N * sizeof( curandState ) );
    setupCuRandState <<< 1, N * N >>> ( _states, seed );
  }

  curandState* get() const { return _states; }

  ~CURAND_STATE() {
    cudaFree(_states);
  }

private:
  curandState* _states;
};

void sample(mat &prob, RBM_TYPE type) {
  static CURAND_STATE state;

  const size_t N = 32;
  dim3 threads(N, N);
  dim3 grid;
  grid.x = (unsigned int) ceil((float) prob.getCols() / N);
  grid.y = (unsigned int) ceil((float) prob.getRows() / N);

  switch (type) {
    case GAUSSIAN_BERNOULLI:
      sampling_kernel<gaussian><<< grid, threads >>>(prob.getData(), state.get(), prob.getRows(), prob.getCols());
      break;
    case BERNOULLI_BERNOULLI:
      sampling_kernel<bernoulli><<< grid, threads >>>(prob.getData(), state.get(), prob.getRows(), prob.getCols());
      break;
  }

  CCE(cudaDeviceSynchronize());
  fill_bias(prob);
}

void up_propagate(const mat& W, const mat& visible, mat& hidden, RBM_TYPE type) {
  switch (type) {
    case BERNOULLI_BERNOULLI:
      hidden = sigmoid(visible * W);
      break;
    case GAUSSIAN_BERNOULLI:
      hidden = visible * W;
      break;
  }
  fill_bias(hidden);
}

void down_propagate(const mat& W, mat& visible, const mat& hidden, RBM_TYPE type) {
  visible = sigmoid(hidden * ~W);
  fill_bias(visible);
}

mat rbmTrain(const hmat& data, size_t nHiddenUnits, float threshold, RBM_TYPE type, float learning_rate) {

  switch (type) {
    case BERNOULLI_BERNOULLI:
      cout << "BERNOULLI_BERNOULLI" << endl;

      // If Bernoulli, make sure the visible units have values in the range [0, 1]
      assert(ext::max(data) <= 1 && ext::min(data) >= 0);
      break;
    case GAUSSIAN_BERNOULLI:
      cout << "GAUSSIAN_BERNOULLI" << endl;

      // Note: The learning rate of Gaussian RBM needs to be about one or two
      // orders of magnitude smaller than when using binary visible units.
      // Otherwise value will explode very quickly and get NaN.
      // [cf. A Practical Guide to Training Restricted Boltzmann Machines]
      learning_rate /= 100;
      break;
  }

  size_t batchSize = 1024;
  size_t input_dim = data.getRows();
  size_t nData = data.getCols();

  mat W(input_dim, nHiddenUnits + 1);
  ext::randn(W, 0, 0.1 / W.getCols());

  size_t minEpoch = 5, maxEpoch = 128;

  std::vector<float> errors;
  errors.reserve(maxEpoch);

  float initialSlope = 0;

  ProgressBar pBar("RBM init ( error = ...       , slope ratio = ...        )");

  perf::Timer timer;
  timer.start();
  size_t epoch;
  for (epoch=0; epoch < maxEpoch; ++epoch) {

    float error = 0;

    Batches batches(batchSize, nData);
    for (Batches::iterator itr = batches.begin(); itr != batches.end(); ++itr) {

      mat v1, v2, h1, h2;

      v1 = getBatchData(data, *itr);
      fill_bias(v1);

      // Up propagation
      up_propagate(W, v1, h1, type);

      // Calculate positive
      mat positive = ~v1 * h1;

      // Sampling
      sample(h1, type);

      // Down-and-Up propagation
      down_propagate(W, v2, h1, type);
      up_propagate(W, v2, h2, type);

      // Calculate negative
      mat negative = ~v2 * h2;

      float lr = learning_rate / batchSize;
      mat dW = lr * (positive - negative);

      W += dW;
      error += pow(nrm2(v1 - v2), 2.0f);
    }

    errors.push_back(sqrt(error) / nData );

    if (epoch == minEpoch)
      initialSlope = getSlope(errors, minEpoch);

    if (epoch > minEpoch) {
      float ratio = abs(getSlope(errors, 5) / initialSlope);
      float percentage = (epoch == maxEpoch - 1) ? 1.0 : std::min(1.0f, threshold / ratio);

      char status[100];
      sprintf(status, "RBM init ( error = %.4e, slope ratio = %.4e )", errors[epoch], ratio);

      pBar.refresh(percentage, status);

      if (ratio < threshold)
	break;
    }
  }

  printf("Average magnitude of element in weight W = %.7f\n", nrm2(W) / sqrt(W.size()));
  float t_end = timer.getTime();
  printf("# of epoch = %lu, average time for each epoch = %f\n", epoch, t_end / epoch);
  
  return W;
}

// Show a dialogue and ask user for the output dimension
size_t getOutputDimension() {
  string userInput = "";

  while (!is_number(userInput)) {
    printf("\33[33m Since RBM is a kind of UNSUPERVISED pre-training. "
	   "Please enter how many nodes you want in the output layer.\33[0m "
	   "[      ]\b\b\b\b\b");
    cin >> userInput;
  }

  return atoi(userInput.c_str());
}

std::vector<size_t> getDimensionsForRBM(
    size_t input_dim, 
    const string& hidden_structure, 
    size_t output_dim) {

  // ===========================================================================
  // Initialize hidden structure
  std::vector<size_t> dims = splitAsInt(hidden_structure, '-');
  dims.insert(dims.begin(), input_dim);
  dims.push_back((size_t) output_dim);

  printf("\n");
  printf("\33[32m Start RBM pre-training with following hidden structure:\33[0m\n");
  printf("\33[34m [   input  layer  ]\33[0m %lu\n", dims[0]);
  for (size_t i=1; i<dims.size()-1; ++i)
    printf("\33[34m [ hidden layer #%-2lu]\33[0m %lu\n", i, dims[i]);
  printf("\33[34m [   output layer  ]\33[0m %lu\n\n", dims.back());
  // ===========================================================================

  return dims;
}

float getSlope(const std::vector<float> &seq, size_t N) {
  std::vector<float> x(N);
  for (size_t i=0; i<N; ++i)
    x[i] = N - 1 - i;

  std::vector<float> y(N);
  for (size_t i=seq.size() - N; i<seq.size(); ++i)
    y[i - (seq.size() - N)] = seq[i];

  float m, c;
  linearRegression(x, y, &m, &c);

  return m;
}

float getAsymptoticBound(const std::vector<float> &error, size_t epoch, size_t maxEpoch, size_t N) {
  std::vector<float> x(N);
  for (size_t i=0; i<N; ++i)
    x[i] = epoch - (N - 1 - i);

  std::vector<float> y(N);
  for (size_t i=error.size() - N; i<error.size(); ++i)
    y[i - (error.size() - N)] = error[i];

  float m, c;
  linearRegression(x, y, &m, &c);

  return m * (float) maxEpoch + c;
}

/*mat sum(mat& m, size_t dimension = 1) {
  if (dimension == 1)
    return (mat(1, m.getRows()) += 1) * m;
  else
    return m * (mat(m.getCols(), 1) += 1);
} */
