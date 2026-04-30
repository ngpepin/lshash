#include "blaze3.cuh"

#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <vector>
#include <filesystem>

extern "C" {

struct Blake3GpuContext {
    Chunk *device_memory;
    int max_chunks;
};

Blake3GpuContext* blake3_gpu_create(int max_chunks) {
    if (max_chunks <= 0) {
        return nullptr;
    }

    // Force CUDA context initialization once.
    cudaFree(0);

    Blake3GpuContext *ctx = new Blake3GpuContext;
    ctx->max_chunks = max_chunks;
    ctx->device_memory = nullptr;

    cudaError_t err = cudaMalloc(
        &ctx->device_memory,
        max_chunks * sizeof(Chunk)
    );

    if (err != cudaSuccess) {
        delete ctx;
        return nullptr;
    }

    return ctx;
}

void blake3_gpu_destroy(Blake3GpuContext *ctx) {
    if (!ctx) return;

    if (ctx->device_memory) {
        cudaFree(ctx->device_memory);
    }

    delete ctx;
}

int blake3_gpu_hash_file(
    Blake3GpuContext *ctx,
    const char *path,
    uint8_t *out_hash32
) {
    if (!ctx || !path || !out_hash32) {
        return -1;
    }

    std::ifstream file(path, std::ios::binary);

    if (file.fail()) {
        return -2;
    }

    std::filesystem::path fyle{path};
    uint64_t file_size = std::filesystem::file_size(fyle);

    Hasher hasher = Hasher::_new(file_size);
    hasher.init();

    /*
        This assumes Hasher::_new(file_size) never needs more chunks than
        ctx->max_chunks. If your Hasher exposes the real chunk count, check it
        here and return an error when ctx->max_chunks is too small.
    */

    char buffer[CHUNK_LEN] = {0};

    file.read(buffer, CHUNK_LEN);

    while (file.gcount()) {
        hasher.update(buffer, file.gcount());
        file.read(buffer, CHUNK_LEN);
    }

    std::vector<uint8_t> hash_output(32);

    /*
        The important part: use ctx->device_memory as the reusable GPU buffer.
        This depends on your Hasher/finalize implementation eventually calling
        light_hash(..., memory_bar). If your current finalize allocates memory
        internally, you will need to thread ctx->device_memory into it.
    */
    hasher.memory_bar = ctx->device_memory; // Only if this member exists.
    hasher.finalize(hash_output);

    std::memcpy(out_hash32, hash_output.data(), 32);

    return 0;
}

}
