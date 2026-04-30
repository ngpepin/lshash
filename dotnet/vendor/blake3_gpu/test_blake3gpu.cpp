#include <cstdint>
#include <cstdio>
#include <cstdlib>

extern "C" {
    struct Blake3GpuContext;

    Blake3GpuContext* blake3_gpu_create(int max_chunks);
    void blake3_gpu_destroy(Blake3GpuContext *ctx);

    int blake3_gpu_hash_file(
        Blake3GpuContext *ctx,
        const char *path,
        uint8_t *out_hash32
    );
}

static void print_hex(const uint8_t hash[32]) {
    for (int i = 0; i < 32; i++) {
        std::printf("%02x", hash[i]);
    }
    std::printf("\n");
}

int main(int argc, char **argv) {
    if (argc < 2) {
        std::fprintf(stderr, "Usage: %s <file> [repeat]\n", argv[0]);
        return 1;
    }

    const char *path = argv[1];
    int repeat = argc >= 3 ? std::atoi(argv[2]) : 1;

    // 1 GiB worth of 1024-byte BLAKE3 chunks.
    // Increase this if you test larger files.
    int max_chunks = 1 << 20;

    Blake3GpuContext *ctx = blake3_gpu_create(max_chunks);

    if (!ctx) {
        std::fprintf(stderr, "Failed to create GPU context\n");
        return 2;
    }

    uint8_t hash[32] = {0};

    for (int i = 0; i < repeat; i++) {
        int rc = blake3_gpu_hash_file(ctx, path, hash);

        if (rc != 0) {
            std::fprintf(stderr, "blake3_gpu_hash_file failed: rc=%d\n", rc);
            blake3_gpu_destroy(ctx);
            return 3;
        }
    }

    print_hex(hash);

    blake3_gpu_destroy(ctx);
    return 0;
}
