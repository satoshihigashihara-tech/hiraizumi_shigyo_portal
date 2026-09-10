/** @type {import('next').NextConfig} */
const nextConfig = {
  experimental: {
    serverActions: {
      // 5 MiB file plus multipart form overhead.
      bodySizeLimit: "6mb",
    },
  },
};

export default nextConfig;
