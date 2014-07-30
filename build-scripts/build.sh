#!/bin/sh

me=$(basename $0)

usage="\
Usage: $0 [OPTIONS] [PACKAGE[PREFIX[CONF_OPT]]]
OPTIONS:
  -h, --help               print this help, then exit
  -A, --autoreconf         force run ./autogen.sh and autoreconf
  -C, --clean              make clean
  -D, --distclean          make distclean
  -c, --configure          force run configure
  -f, --force              force to rebuild
  -i, --install            force to install
  -t, --toolchain=TOOLCHAIN
                           choose the toolchain [default=v100]
  -v, --verbose            verbose output
      --prefix=PREFIX      install files in PREFIX
                           [/usr]
"

help="
Try \`$me --help' for more information."

force_ac=no
force_conf=no
force_build=no
force_install=no
make_clean=no
make_distclean=no
verbose=no
tc=v100

# Parse command line
while [ $# -gt 0 ]; do
  case $1 in
    --help | -h)
      echo "$usage" ; exit ;;
    -A | --autoreconf)
      force_ac=yes ; shift ;;
    -C | --clean)
      make_clean=yes ; shift ;;
    -D | --distclean)
      make_distclean=yes ; shift ;;
    -c | --configure)
      force_conf=yes ; shift ;;
    -f | --force)
      force_build=yes ; shift ;;
    -i | --install)
      force_install=yes ; shift ;;
    --prefix=*)
      prefix=$(expr "X$1" : '[^=]*=\(.*\)') ; shift ;;
    -t)
      shift ; tc=$1 ; shift ;;
    --toolchain=*)
      tc=$(expr "X$1" : '[^=]*=\(.*\)') ; shift ;;
    -v | --verbose)
      verbose=yes ; shift ;;
    -*)
      echo "$me: invalid option $1${help}" >&2
      exit 1 ;;
    *) # Stop option processing
      break ;;
  esac
done

BUILD=${MACHTYPE}
case ${tc} in
  v100)
    if ! which arm-hisiv100nptl-linux-gcc > /dev/null 2>&1; then
      PATH=${PATH}:/opt/hisi-linux-nptl/arm-hisiv100-linux/target/bin
    fi
    TARGET=arm-hisiv100nptl-linux
    TARGET_ROOTFS=rootfs_uclibc
    ;;
  v200)
    if ! which arm-hisiv200-linux-gcc > /dev/null 2>&1; then
      PATH=${PATH}:/opt/hisi-linux/x86-arm/arm-hisiv200-linux/target/bin
    fi
    TARGET=arm-hisiv200-linux
    TARGET_ROOTFS=rootfs_glibc
    ;;
  *)
    echo "$me: invalid toolchain ${tc}${help}"
    exit 1 ;;
esac
export PATH

if [ "x${NR_CPUS}" = "x" ]; then
  NR_CPUS=$(expr $(cat /proc/cpuinfo | grep 'processor' | wc -l) \* 2)
fi
export NR_CPUS

DEF_CONF_OPTS=" --build=${BUILD} --host=${TARGET} "

CROSS_COMPILE=${TARGET}-

BUILD_HOME=${PWD}
BUILD_LOG=${BUILD_HOME}/build.log
SOURCE_HOME=${BUILD_HOME}/sources
BUILD_TMP=${BUILD_HOME}/tmp
SYSROOT=${BUILD_HOME}/${TARGET_ROOTFS}
DESTDIR=${SYSROOT}

PREFIX=/usr
if [ x"$prefix" != "x" ]; then
  PREFIX=$prefix
fi

PKG_CONFIG_PATH=${SYSROOT}${PREFIX}/lib/pkgconfig
PKG_CONFIG_SYSROOT_DIR=${SYSROOT}

export DESTDIR
export PKG_CONFIG_PATH PKG_CONFIG_SYSROOT_DIR

CPPFLAGS="-I${SYSROOT}${PREFIX}/include"
LDFLAGS="-L${SYSROOT}/lib -L${SYSROOT}${PREFIX}/lib -lstdc++"
#LDFLAGS+="-Wl,-rpath-link -Wl,${SYSROOT}${PREFIX}/lib "\
#         "-Wl,-rpath -Wl,/lib -Wl,-rpath -Wl,${PREFIX}/lib"
export CPPFLAGS LDFLAGS

function __fatal() {
  echo
  echo "FATAL: $*"
  echo "See build.log for detail."
  echo
}

function __warn() {
  echo
  echo "WARN: $*"
  echo
}

function __display_banner() {
  echo
  echo "*********************************************************************"
  echo "* Building $1"
  echo "*********************************************************************"
  echo
}

function fatal() {
  __fatal $* | tee -a ${BUILD_LOG} >&2
  exit 1
}

function warn() {
  __warn $* | tee -a ${BUILD_LOG} >&2
}

function display_banner() {
  __display_banner $* | tee -a ${BUILD_LOG}
}

## Prepare the build environment
rm -f ${BUILD_LOG}

no_initial_rootfs_warn="\
Initial rootfs not found.

to build without rootfs, libstdc++.la from the toolchain directory
show be deleted, which reference the incorrect path."

if ! [ -d ${SYSROOT} ]; then
  if [ -f ${TARGET_ROOTFS}.tgz ]; then
    tar -zvxf ${TARGET_ROOTFS}.tgz
  else
    echo "$no_initial_rootfs_warn"
    sleep 2
  fi
  force_install=yes
fi

function patch_lt_objects() {
  if [ $# -lt 2 ]; then
    return;
  fi
  local prefix=$1
  shift
  pushd ${SYSROOT}${prefix}/lib > /dev/null
    local lt_objs=$(ls $*)
    local opts=" -e s;libdir='${prefix};libdir='${SYSROOT}${prefix};"
    local lt_obj=
    for lt_obj in ${lt_objs}; do
      local fn=$(basename ${lt_obj})
      opts+=" -e ""s;${prefix}/lib/${fn};${SYSROOT}${prefix}/lib/${fn};"
    done
    sed -i ${opts} ${lt_objs}
  popd > /dev/null
}


#
# function: build_ac_package package_name package_path prefix
# parameters:
#   $1           package name
#   $2           package path
#   $3           prefix       [default=/usr]
#   $4           optional config options
#
function build_ac_package() {
  local f_ac=${force_ac}
  local f_conf=${force_conf}
  local f_build=${force_build}
  local f_inst=${force_install}

  ## Parse options
  while [ $# -gt 0 ]; do
    case $1 in
      -f)
        f_build=yes ; shift ;;
      -A)
        f_ac=yes ; shift ;;
      -c)
        f_conf=yes ; shift ;;
      -i)
        f_build=yes ; shift ;;
      *)  ## Stop option processing
        break ;;
    esac
  done

  if [ $# -lt 2 ]; then
    fatal 'Usage build_ac_package NAME PATH [PREFIX] [CONF_OPTS]' >&2
  fi

  local ltobjs=""

  local pkg_name=$1; shift
  local pkg_path=$1; shift
  local prefix=/usr

  if [ $# -gt 0 ]; then
    prefix=$1;   shift
  fi

  if ! [ -d ${SOURCE_HOME}/${pkg_path} ]; then
    fatal "Package ${pkg_name} not found"
  fi

  display_banner "$pkg_name at ${SOURCE_HOME}/${pkg_path}"

  ## check if package has already been built succesful
  if [ -f ${BUILD_TMP}/.${pkg_path}-built-ok \
       -a "x${f_build}" != "xyes" \
       -a "x${f_inst}" != "xyes" \
     ];
  then
    return
  fi

  ## make distclean
  if [ "x${make_distclean}" = "xyes" ]; then
    if [ -f ${SOURCE_HOME}/${pkg_path}/Makefile ]; then
      make distclean -C ${SOURCE_HOME}/${pkg_path} >>${BUILD_LOG} 2>&1
    fi
    rm -f ${BUILD_TMP}/.${pkg_path}-built-ok
    return
  fi

  ## make clean
  if [ "x${make_clean}" = "xyes" ]; then
    if [ -f ${SOURCE_HOME}/${pkg_path}/Makefile ]; then
      make clean -C ${SOURCE_HOME}/${pkg_path} >>${BUILD_LOG} 2>&1
    fi
    rm -f ${BUILD_TMP}/.${pkg_path}-built-ok
    return
  fi

  pushd ${SOURCE_HOME}/${pkg_path} > /dev/null
    ## run ./autogen.sh and autoreconf
    if [ "x${f_ac}" = "xyes" ]; then
      if [ -f autogen.sh ]; then
        ./autogen.sh -h >>${BUILD_LOG} 2>&1
      fi
      autoreconf >>${BUILD_LOG} 2>&1
    fi
    ## configure
    if ! [ -f Makefile -a "x${f_conf}" != "xyes" ]; then
      ./configure --prefix=${prefix} \
          ${DEF_CONF_OPTS} $* >>${BUILD_LOG} 2>&1 \
          || fatal "error building $pkg_name"
    fi
    ## build and install
    make -j${NR_CPUS} >>${BUILD_LOG} 2>&1 \
      || fatal "error building ${pkg_name}"
    ## install to tmp directory to find all .la files
    make install DESTDIR=${BUILD_TMP} >>${BUILD_LOG} 2>&1 \
      || fatal "error building ${pkg_name}"
    if [ -d ${BUILD_TMP}${prefix}/lib ]; then
      pushd ${BUILD_TMP}${prefix}/lib > /dev/null
        ltobjs=$(find -name "lib*.la" | sed 's;\./;;')
        find -name "lib*.la" -delete
      popd > /dev/null
    fi
    make install DESTDIR=${SYSROOT} >>${BUILD_LOG} 2>&1 \
      || fatal "error building ${pkg_name}"
    ## patch all libtool .la files
    if [ "x${ltobjs}" != "x" ]; then
      patch_lt_objects ${prefix} ${ltobjs}
    fi
    ## Succeed, mark this package
    touch ${BUILD_TMP}/.${pkg_path}-built-ok
  popd > /dev/null
}

## Build listed-packages
if [ $# -gt 0 ]; then
  pkg=$1 ; shift
  build_ac_package ${pkg} ${pkg} $*
  exit 0
fi


pushd sources/zlib-1.2.8 >/dev/null
  display_banner ZLIB
  ## make distclean
  if [ x"$make_distclean" = "xyes" ]; then
    make distclean >>${BUILD_LOG} 2>&1
  ## make clean
  elif [ x"$make_clean" = "xyes" ]; then
    make clean >>${BUILD_LOG} 2>&1
  else
    if ! [ -f ${BUILD_TMP}/.zlib-1.2.8-built-ok \
      -a x"$force_build" != "xyes" \
      -a x"$force_install" != "xyes" ];
    then
      ## configure,make and install
      CC=${CROSS_COMPILE}gcc \
      ./configure --prefix=${PREFIX} >>${BUILD_LOG} 2>&1 || exit 1;
      CC=${CROSS_COMPILE}gcc make -j${NR_CPUS} >>${BUILD_LOG} 2>&1 || exit 1;
      CC=${CROSS_COMPILE}gcc make install >>${BUILD_LOG} 2>&1 || exit 1;
      touch ${BUILD_TMP}/.zlib-1.2.8-built-ok
    fi
  fi
popd >/dev/null


pushd sources/http-parser-2.3 >/dev/null
  display_banner HTTP-PARSER
  ## clean and distclean
  if [ x"$make_clean" = "xyes" -o x"$make_distclean" = "xyes" ]; then
    rm -f ${SYSROOT}${PREFIX}/lib/libhttp_parser.so*
    rm -f ${SYSROOT}${PREFIX}/include/http_parser.h
  else
    ## build and install
    CC=${CROSS_COMPILE}gcc \
    AR=${CROSS_COMPILE}ar \
    make library >>${BUILD_LOG} 2>&1 || fatal "error building HTTP-PARSER"
    cp -v libhttp_parser.so.2.3 ${SYSROOT}${PREFIX}/lib \
      >>${BUILD_LOG} 2>&1 || fatal "error installing HTTP-PARSER"
    pushd ${SYSROOT}${PREFIX}/lib >/dev/null
      ln -sf libhttp_parser.so.2.3 libhttp_parser.so
    popd >/dev/null
    mkdir -p ${SYSROOT}${PREFIX}/include
    cp -v http_parser.h ${SYSROOT}${PREFIX}/include \
      >>${BUILD_LOG} 2>&1 || fatal "error installing HTTP-PARSER"
  fi
popd >/dev/null


build_ac_package ZeroMQ zeromq-4.0.4 ${PREFIX} \
    --without-documentation \
    --enable-shared --disable-static


build_ac_package CZMQ czmq-2.2.0 ${PREFIX} \
    --enable-shared --disable-static


build_ac_package LIGHTTPD lighttpd-1.4.35 ${PREFIX} \
    --enable-shared --disable-static \
    --without-zlib --without-bzip2 \
    --enable-lfs --disable-ipv6 \
    --without-pcre --disable-mmap


build_ac_package GETTEXT gettext-0.18.3.2 ${PREFIX} \
    --enable-shared --disable-static \
    --disable-openmp --disable-acl \
    --disable-curses \
    --without-emacs --without-git --without-cvs \
    --without-bzip2 --without-xz


build_ac_package libFFI libffi-3.0.13 ${PREFIX} \
    --enable-shared --disable-static


build_ac_package GLIB glib-2.40.0 ${PREFIX} \
    --enable-shared --disable-static \
    --with-libiconv=no --disable-selinux \
    --disable-gtk-doc --disable-gtk-doc-html --disable-gtk-doc-pdf \
    --disable-man \
    --disable-xattr \
    --disable-dtrace --disable-systemtap \
    glib_cv_stack_grows=no glib_cv_uscore=yes \
    ac_cv_func_posix_getpwuid_r=yes ac_cv_func_posix_getgrgid_r=yes


build_ac_package JSON-GLIB json-glib-1.0.0 ${PREFIX} \
    --enable-shared --disable-static \
    --disable-gtk-doc --disable-gtk-doc-html --disable-gtk-doc-pdf \
    --disable-man \
    --disable-glibtest \
    --disable-introspection \
    --disable-nls


#build_ac_package HARFBUZZ harfbuzz-0.9.33 ${PREFIX} \
#    --enable-shared --disable-static \
#    --disable-gtk-doc --disable-gtk-doc-html \
#    --disable-introspection \
#    --without-cairo --without-freetype \
#    --without-icu


build_ac_package LIBPNG libpng-1.2.50 ${PREFIX} \
    --enable-shared --disable-static
if [ x"$make_clean" != "xyes" -a x"$make_distclean" != "xyes" ]; then
  sed -i -e "s;includedir=\"${PREFIX};includedir=\"${SYSROOT}${PREFIX};" \
      -e "s;libdir=\"${PREFIX};libdir=\"${SYSROOT}${PREFIX};" \
      ${SYSROOT}${PREFIX}/bin/libpng-config
fi


build_ac_package -c FreeType freetype-2.5.3 ${PREFIX} \
    --enable-shared --disable-static \
    --with-zlib --without-bzip2 \
    --with-png --with-harfbuzz=no \
    --without-old-mac-fonts --without-fsspec --without-fsref \
    --without-quickdraw-toolbox --without-quickdraw-carbon \
    --without-ats
if [ x"$make_clean" != "xyes" -a x"$make_distclean" != "xyes" ]; then
  sed -i -e "s;includedir=\"${PREFIX};includedir=\"${SYSROOT}${PREFIX};" \
      -e "s;libdir=\"${PREFIX};libdir=\"${SYSROOT}${PREFIX};" \
      ${SYSROOT}${PREFIX}/bin/freetype-config
fi


build_ac_package SDL2 SDL2-2.0.1 ${PREFIX} \
    --disable-audio --disable-video --disable-render \
    --disable-event --disable-joystick \
    --disable-haptic --disable-power \
    --disable-filesystem --enable-threads \
    --disable-file --disable-loadso --disable-cpuinfo \
    --disable-assembly --disable-ssemath \
    --disable-mmx --disable-3dnow --disable-sse --disable-sse2 \
    --disable-oss --disable-alsa --disable-alsatest \
    --disable-esd --disable-pulseaudio \
    --disable-arts  --disable-nas --disable-sndio --disable-diskaudio \
    --disable-dummyaudio --disable-video-x11 \
    --disable-directfb --disable-fusionsound \
    --disable-libudev --disable-dbus \
    --disable-input-tslib --enable-pthread \
    --disable-directx --enable-sdl-dlopen \
    --disable-clock_gettime --enable-rpath \
    --disable-render-d3d


build_ac_package SDL2_ttf SDL2_ttf-2.0.12 ${PREFIX} \
    --enable-shared --disable-static \
    --disable-sdltest --without-x \
    --with-sdl-prefix=${SYSROOT}${PREFIX} \
    --with-freetype-prefix=${SYSROOT}${PREFIX}


build_ac_package YAML yaml-0.1.5 ${PREFIX} \
    --enable-shared --disable-static


build_ac_package SQLITE sqlite-3.8.4.3 ${PREFIX} \
    --enable-shared --disable-static


LDFLAGS="${LDFLAGS} -lintl" \
build_ac_package GOM gom ${PREFIX} \
    --enable-shared --disable-static \
    --disable-glibtest \
    --disable-nls \
    --disable-gtk-doc --disable-gtk-doc-html --disable-gtk-doc-pdf \
    --disable-introspection


# Build live555
pushd ${SOURCE_HOME}/live >/dev/null
  display_banner "LIVE555"
  ## make distclean
  if [ x"$make_distclean" = "xyes" ]; then
    make distclean >>${BUILD_LOG} 2>&1
  ## make clean
  elif [ x"$make_clean" = "xyes" ]; then
    make clean >>${BUILD_LOG} 2>&1
  else
    if ! [ -f ${BUILD_TMP}/.live555-built-ok \
        -a x"$force_build" != "xyes" \
        -a x"$force_install" != "xyes" ];
    then
      ./genMakefiles armlinux-with-shared-libraries >>${BUILD_LOG} 2>&1 \
        || fatal "error building live555."
      make -j${NR_CPUS} PREFIX=${PREFIX} \
        >>${BUILD_LOG} 2>&1 || fatal "error building live555"
      ## remove last build files before install
      rm -f ${SYSROOT}${PREFIX}/lib/libliveMedia* 2>/dev/null
      rm -f ${SYSROOT}${PREFIX}/lib/libgroupsock* 2>/dev/null
      rm -f ${SYSROOT}${PREFIX}/lib/libUsageEnvironment* 2>/dev/null
      rm -f ${SYSROOT}${PREFIX}/lib/libBasicUsageEnvironment* 2>/dev/null
      make install DESTDIR=${DESTDIR} >>${BUILD_LOG} 2>&1 \
        || fatal "error building live555."
      touch ${BUILD_TMP}/.live555-built-ok
    fi
  fi
popd >/dev/null


build_ac_package LIBIPCAM_BASE libipcam_base ${PREFIX} \
    --enable-shared --disable-static


build_ac_package ICONFIG iconfig ${PREFIX} \
    --sysconfdir=/etc


NR_CPUS=1 \
build_ac_package IONVIF ionvif ${PREFIX} \
    --enable-shared --disable-static \
    --disable-ipv6 \
    --disable-ssl --disable-gnutls \
    --disable-samples \
    ac_cv_func_malloc_0_nonnull=yes


build_ac_package IMEDIA imedia ${PREFIX} \
    --enable-hi3518 --disable-hi3516


CXXFLAGS="-I${SYSROOT}${PREFIX}/include \
          -I${SYSROOT}${PREFIX}/include/liveMedia \
          -I${SYSROOT}${PREFIX}/include/groupsock \
          -I${SYSROOT}${PREFIX}/include/BasicUsageEnvironment \
          -I${SYSROOT}${PREFIX}/include/UsageEnvironment" \
LDFLAGS=" -L${SYSROOT}${PREFIX}/lib -lffi" \
build_ac_package IRTSP irtsp ${PREFIX}

echo
echo "Build completely successful."
echo
