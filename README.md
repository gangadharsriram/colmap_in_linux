
# Installation of Colmap for Linux with cuda  

Step By Step Installation Guide For Colmap In Linux 


## Colmap 

Requirements 

```
sudo apt-get install \
    git \
    cmake \
    ninja-build \
    build-essential \
    libboost-program-options-dev \
    libboost-filesystem-dev \
    libboost-graph-dev \
    libboost-system-dev \
    libeigen3-dev \
    libflann-dev \
    libfreeimage-dev \
    libmetis-dev \
    libgoogle-glog-dev \
    libgtest-dev \
    libsqlite3-dev \
    libglew-dev \
    qtbase5-dev \
    libqt5opengl5-dev \
    libcgal-dev \
    libceres-dev
```

# For headless (with No Display)

```
apt-get install -y xvfb
```

# If Conda Is Active, Kindly Deactivate Conda Environment  

```
conda deactivate
```
# install colmap

```
git clone https://github.com/colmap/colmap.git
cd colmap
mkdir build
cd build
```

### Ensuring Compatibility Between CUDA Architecture and Gencode for NVIDIA Architectures

Identify Your GPU and Its Corresponding CUDA Architecture

Identify Your GPU: Determine the model of your NVIDIA GPU.

Find the CUDA Architecture: Based on your GPU model, identify the corresponding CUDA architecture. Refer to the NVIDIA CUDA Compiler Driver documentation to find the architecture name.

https://docs.nvidia.com/cuda/cuda-compiler-driver-nvcc/#virtual-architecture-feature-list

Get the Gencode: Use the identified CUDA architecture to determine the correct gencode value.

Update CMake Configuration: Replace XX in the following CMake command with your specific CUDA architecture:

cmake -GNinja -DCMAKE_CUDA_ARCHITECTURES="XX"

```
#Example
cmake -GNinja -DCMAKE_CUDA_ARCHITECTURES="80;86;87" .. # Ampere arch only
ninja
sudo ninja install
```

## Vertify

You can now run COLMAP with GPU support using the following commands:

```
colmap -h  # To check if the installation was successful and display help
colmap gui  # To launch the GUI

```



