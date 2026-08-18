#!/bin/bash

# Encerra o script em erro de execução não tratado
set -e

abort()
{
    echo "-----------------------------------------------"
    echo "Kernel compilation failed! Exiting..."
    echo "-----------------------------------------------"
    exit 1
}

# Captura falhas e garante execução da função abort
trap 'abort' ERR

unset_flags()
{
    cat << EOF
Usage: $(basename "$0") [options]
Options:
    -m, --model [value]    Specify the model code of the phone
    -k, --ksu [y/N]        Include KernelSU
    -r, --recovery [y/N]   Compile kernel for an Android Recovery
    -d, --dtbs [y/N]       Compile only DTBs
EOF
}

# Parser de argumentos
while [[ $# -gt 0 ]]; do
    case "$1" in
        --model|-m)
            MODEL="$2"
            shift 2
            ;;
        --ksu|-k)
            KSU_OPTION="$2"
            shift 2
            ;;
        --recovery|-r)
            RECOVERY_OPTION="$2"
            shift 2
            ;;
        --dtbs|-d)
            DTB_OPTION="$2"
            shift 2
            ;;
        *)
            unset_flags
            exit 1
            ;;
    esac
done

if [ -z "$MODEL" ]; then
    echo "Erro: O parâmetro --model é obrigatório."
    unset_flags
    exit 1
fi

echo "Preparing the build environment..."

# Garante o diretório base correto
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

CORES=$(nproc 2>/dev/null || cat /proc/cpuinfo | grep -c processor)

# Define toolchain variables
CLANG_DIR="$PWD/toolchain/clang-r416183b"
export PATH="$CLANG_DIR/bin:$PATH"

MAKE_ARGS=(
    LLVM=1
    LLVM_IAS=1
    ARCH=arm64
    O=out
)

# Define specific variables
KERNEL_DEFCONFIG="extreme_${MODEL}_defconfig"
case "$MODEL" in
    x1slte) BOARD="SRPSJ28B018KU" ;;
    x1s)    BOARD="SRPSI19A018KU" ;;
    y2slte) BOARD="SRPSJ28A018KU" ;;
    y2s)    BOARD="SRPSG12A018KU" ;;
    z3s)    BOARD="SRPSI19B018KU" ;;
    c1slte) BOARD="SRPTC30B009KU" ;;
    c1s)    BOARD="SRPTB27D009KU" ;;
    c2slte) BOARD="SRPTC30A009KU" ;;
    c2s)    BOARD="SRPTB27C009KU" ;;
    r8s)    BOARD="SRPTF26B014KU" ;;
    *)
        echo "Modelo desconhecido: $MODEL"
        unset_flags
        exit 1
        ;;
esac

if [[ "$RECOVERY_OPTION" == "y" ]]; then
    RECOVERY="recovery.config"
    KSU_OPTION="n"
fi

if [ -z "$KSU_OPTION" ]; then
    read -rp "Include KernelSU (y/N): " KSU_OPTION
fi

if [[ "$KSU_OPTION" == "y" || "$KSU_OPTION" == "Y" ]]; then
    KSU="ksu.config"
fi

if [[ "$DTB_OPTION" == "y" || "$DTB_OPTION" == "Y" ]]; then
    DTBS="y"
fi

rm -rf "build/out/$MODEL"
mkdir -p "build/out/$MODEL/zip/files"
mkdir -p "build/out/$MODEL/zip/META-INF/com/google/android"

# Build kernel image
echo "-----------------------------------------------"
echo "Defconfig: $KERNEL_DEFCONFIG"
echo "KSU: ${KSU:-N}"
echo "Recovery: ${RECOVERY:-N}"
echo "-----------------------------------------------"

if [ -z "$DTBS" ]; then
    echo "Building kernel using $MODEL.config"
else
    echo "Building DTBs using $MODEL.config"
fi

echo "Generating configuration file..."
echo "-----------------------------------------------"

# Monta o comando do make com configs condicionais
CONFIG_TARGETS=("exynos9830_defconfig" "$MODEL.config")
[ -n "$KSU" ] && CONFIG_TARGETS+=("$KSU")
[ -n "$RECOVERY" ] && CONFIG_TARGETS+=("$RECOVERY")

make "${MAKE_ARGS[@]}" -j"$CORES" "${CONFIG_TARGETS[@]}"

if [ -n "$DTBS" ]; then
    echo "Building DTBs..."
    make "${MAKE_ARGS[@]}" -j"$CORES" dtbs
else
    echo "Building kernel..."
    make "${MAKE_ARGS[@]}" -j"$CORES"
fi

# Define constant variables
DTB_PATH="build/out/$MODEL/dtb.img"
KERNEL_PATH="build/out/$MODEL/Image"
KERNEL_OFFSET="0x00008000"
DTB_OFFSET="0x00000000"
RAMDISK_OFFSET="0x01000000"
SECOND_OFFSET="0xF0000000"
TAGS_OFFSET="0x00000100"
BASE="0x10000000"
CMDLINE=''
HASHTYPE="sha1"
HEADER_VERSION="2"
OS_PATCH_LEVEL="2025-08"
OS_VERSION="16.0.0"
PAGESIZE="2048"
RAMDISK="build/out/$MODEL/ramdisk.cpio.gz"
OUTPUT_FILE="build/out/$MODEL/boot.img"

## Build auxiliary boot.img files
if [ -z "$DTBS" ]; then
    cp out/arch/arm64/boot/Image "build/out/$MODEL/"
fi

# Build dtb
echo "Building common exynos9830 Device Tree Blob Image..."
echo "-----------------------------------------------"
./toolchain/mkdtimg cfg_create "build/out/$MODEL/dtb.img" build/dtconfigs/exynos9830.cfg -d out/arch/arm64/boot/dts/exynos

# Build dtbo
echo "Building Device Tree Blob Output Image for $MODEL..."
echo "-----------------------------------------------"
./toolchain/mkdtimg cfg_create "build/out/$MODEL/dtbo.img" "build/dtconfigs/$MODEL.cfg" -d out/arch/arm64/boot/dts/samsung

if [ -z "$RECOVERY" ] && [ -z "$DTBS" ]; then
    # Build ramdisk
    echo "Building RAMDisk..."
    echo "-----------------------------------------------"
    pushd build/ramdisk > /dev/null
    find . ! -name . | LC_ALL=C sort | cpio -o -H newc -R root:root | gzip > "../out/$MODEL/ramdisk.cpio.gz"
    popd > /dev/null
    echo "-----------------------------------------------"

    # Create boot image
    echo "Creating boot image..."
    echo "-----------------------------------------------"
    ./toolchain/mkbootimg --base "$BASE" --board "$BOARD" --cmdline "$CMDLINE" --dtb "$DTB_PATH" \
        --dtb_offset "$DTB_OFFSET" --hashtype "$HASHTYPE" --header_version "$HEADER_VERSION" --kernel "$KERNEL_PATH" \
        --kernel_offset "$KERNEL_OFFSET" --os_patch_level "$OS_PATCH_LEVEL" --os_version "$OS_VERSION" --pagesize "$PAGESIZE" \
        --ramdisk "$RAMDISK" --ramdisk_offset "$RAMDISK_OFFSET" \
        --second_offset "$SECOND_OFFSET" --tags_offset "$TAGS_OFFSET" -o "$OUTPUT_FILE"

    # Build zip
    echo "Building zip..."
    echo "-----------------------------------------------"
    cp "build/out/$MODEL/boot.img" "build/out/$MODEL/zip/files/boot.img"
    cp "build/out/$MODEL/dtbo.img" "build/out/$MODEL/zip/files/dtbo.img"
    cp build/update-binary "build/out/$MODEL/zip/META-INF/com/google/android/update-binary"
    cp build/updater-script "build/out/$MODEL/zip/META-INF/com/google/android/updater-script"

    version=$(grep -o 'CONFIG_LOCALVERSION="[^"]*"' arch/arm64/configs/exynos9830_defconfig | cut -d '"' -f 2 || echo "v1.0")
    version="${version:1}"
    
    pushd "build/out/$MODEL/zip" > /dev/null
    DATE=$(date +"%d-%m-%Y_%H-%M-%S")

    if [[ "$KSU_OPTION" == "y" || "$KSU_OPTION" == "Y" ]]; then
        NAME="${version}_${MODEL}_UNOFFICIAL_KSU_${DATE}.zip"
    else
        NAME="${version}_${MODEL}_UNOFFICIAL_${DATE}.zip"
    fi
    zip -r -qq "../$NAME" .
    popd > /dev/null
fi

echo "Build finished successfully!"
