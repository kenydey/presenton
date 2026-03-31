
const fastapiInternalBaseUrl = (
  process.env.PRESENTON_FASTAPI_INTERNAL_URL || "http://127.0.0.1:8000"
).replace(/\/+$/, "");

const nextConfig = {
  reactStrictMode: false,
  distDir: ".next-build",
  

  // Rewrites for development - proxy API/static requests to FastAPI backend
  async rewrites() {
    return [
      {
        source: "/api/v1/:path*",
        destination: `${fastapiInternalBaseUrl}/api/v1/:path*`,
      },
      {
        source: '/app_data/fonts/:path*',
        destination: `${fastapiInternalBaseUrl}/app_data/fonts/:path*`,
      },
    ];
  },

  images: {
    remotePatterns: [
      {
        protocol: "https",
        hostname: "pub-7c765f3726084c52bcd5d180d51f1255.r2.dev",
      },
      {
        protocol: "https",
        hostname: "pptgen-public.ap-south-1.amazonaws.com",
      },
      {
        protocol: "https",
        hostname: "pptgen-public.s3.ap-south-1.amazonaws.com",
      },
      {
        protocol: "https",
        hostname: "img.icons8.com",
      },
      {
        protocol: "https",
        hostname: "present-for-me.s3.amazonaws.com",
      },
      {
        protocol: "https",
        hostname: "yefhrkuqbjcblofdcpnr.supabase.co",
      },
      {
        protocol: "https",
        hostname: "images.unsplash.com",
      },
      {
        protocol: "https",
        hostname: "picsum.photos",
      },
      {
        protocol: "https",
        hostname: "unsplash.com",
      },
    ],
  },
  
};

export default nextConfig;
