FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
ARG TARGET_RUNTIME=linux-x64
WORKDIR /src

COPY dotnet/LsHash.csproj dotnet/
RUN dotnet restore dotnet/LsHash.csproj

COPY . .
RUN dotnet publish dotnet/LsHash.csproj \
  -c Release \
  -r ${TARGET_RUNTIME} \
  --self-contained true \
  -p:PublishSingleFile=true \
  -p:PublishTrimmed=false \
  -p:IncludeNativeLibrariesForSelfExtract=true \
  -o /out

FROM mcr.microsoft.com/dotnet/runtime-deps:10.0-bookworm-slim
WORKDIR /app
COPY --from=build /out/lshash /usr/local/bin/lshash
ENTRYPOINT ["/usr/local/bin/lshash"]
