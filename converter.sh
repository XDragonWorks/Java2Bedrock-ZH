#!/usr/bin/env bash
: ${1?'请在脚本的同一目录下指定一个输入资源包 (例如: ./converter.sh MyResourcePack.zip)'}

# 定义颜色占位符
C_RED='\e[31m'
C_GREEN='\e[32m'
C_YELLOW='\e[33m'
C_BLUE='\e[36m'
C_GRAY='\e[37m'
C_CLOSE='\e[m'

# 状态消息函数,根据消息类型显示不同样式
# 用法: status <completion|process|critical|error|info|plain> <消息>
status_message () {
  case $1 in
    "completion")
      printf "${C_GREEN}[+] ${C_GRAY}${2}${C_CLOSE}\n"
      ;;
    "process")
      printf "${C_YELLOW}[•] ${C_GRAY}${2}${C_CLOSE}\n"
      ;;
    "critical")
      printf "${C_RED}[X] ${C_GRAY}${2}${C_CLOSE}\n"
      ;;
    "error")
      printf "${C_RED}[错误] ${C_GRAY}${2}${C_CLOSE}\n"
      ;;
    "info")
      printf "${C_BLUE}${2}${C_CLOSE}\n"
      ;;
    "plain")
      printf "${C_GRAY}${2}${C_CLOSE}\n"
      ;;
  esac
}

# 依赖检查函数确保必需的程序已安装
# 用法: dependency_check <程序名称> <程序网站> <测试命令> <grep表达式>
dependency_check () {
  if command ${3} 2>/dev/null | grep -q "${4}"; then
      status_message completion "依赖 ${1} 已满足"
  else
      status_message error "必须安装依赖 ${1} 才能继续\n请查看 ${2}\n退出脚本..."
      exit 1
  fi
}

# 用户输入函数,在需要时提示用户输入信息
# 用法: user_input <提示信息> <默认值> <值描述>
user_input () {
  if [[ -z "${!1}" ]]; then
    status_message plain "${2} ${C_YELLOW}[${3}]\n"
    read -p "${4}: " ${1}
    echo
  fi
}

# 等待作业函数防止下一个作业在没有空闲CPU线程时开始
wait_for_jobs () {
  while test $(jobs -p | wc -w) -ge "$((2*$(nproc)))"; do wait -n; done
}

# 确保输入包存在
if ! test -f "${1}"; then
   status_message error "输入的资源包 ${1} 不在此目录中"
   exit 1
else
  status_message process "检测到输入的文件 ${1}"
fi

# 获取用户定义的启动标志
while getopts w:m:a:b:f:v:r:s:u: flag "${@:2}"
do
    case "${flag}" in
        w) warn=${OPTARG};;
        m) merge_input=${OPTARG};;
        a) attachable_material=${OPTARG};;
        b) block_material=${OPTARG};;
        f) fallback_pack=${OPTARG};;
        v) default_asset_version=${OPTARG};;
	r) rename_model_files=${OPTARG};;
        s) save_scratch=${OPTARG};;
        u) disable_ulimit=${OPTARG};;
    esac
done

if [[ ${disable_ulimit} == "true" ]]
then
  getconf ARG_MAX
  ulimit -s unlimited
  status_message info "已更改脚本的 ulimit 设置:"
  ulimit -a
  echo | xargs --show-limits
  getconf ARG_MAX

fi

# 警告用户脚本的局限性
printf '\e[1;31m%-6s\e[m\n' "
███████████████████████████████████████████████████████████████████████████████
████████████████████████ # <!> # 警 告 # <!> # ████████████████████████
███████████████████████████████████████████████████████████████████████████████
如果您的资源包不完全符合原版资源规范，包括但不限于缺少纹理、
不正确的父级关系、定义不当的谓词以及格式错误的JSON文件等问题，
很可能会导致此脚本失败。在使用此转换器之前修复任何潜在的资源包格式错误。
███████████████████████████████████████████████████████████████████████████████
███████████████████████████████████████████████████████████████████████████████
███████████████████████████████████████████████████████████████████████████████
"

if [[ ${warn} != "false" ]]; then
read -p $'\e[37m按回车键确认并继续。按 Ctrl+C 退出。:\e[0m

'
fi

# 确保我们有所有必需的依赖项
dependency_check "jq-1.6" "https://stedolan.github.io/jq/download/" "jq --version" "1.6"
dependency_check "sponge" "https://joeyh.name/code/moreutils/" "-v sponge" ""
dependency_check "imagemagick" "https://imagemagick.org/script/download.php" "convert --version" ""
dependency_check "7zip" "https://www.7-zip.org/" "7z" "7-Zip"
dependency_check "spritesheet-js" "https://www.npmjs.com/package/spritesheet-js" "-v spritesheet-js" ""
status_message completion "所有依赖项都已安装\n"

# 提示用户进行初始配置
status_message info "现在将询问一些配置问题。默认值以黄色显示。直接按Enter键以使用默认值。\n"
user_input merge_input "此目录中是否有现有的基岩版资源包,您想与输出合并吗? (例如: input.mcpack)" "null" "输入要合并的包"
user_input attachable_material "我们应该为可附着物使用什么材质?" "entity_alphatest_one_sided" "可附着物材质"
user_input block_material "我们应该为方块使用什么材质?" "alpha_test" "方块材质"
user_input fallback_pack "从哪个 URL 下载后备资源包? (必须是直接链接)\n 如果不需要默认资源,请使用 'none'。" "null" "后备包 URL"

# 为用户打印初始配置并设置默认值(如果未指定)
status_message plain "
使用以下设置生成基岩版 3D 资源包:
${C_GRAY}要合并的输入包: ${C_BLUE}${merge_input:=null}
${C_GRAY}可附着物材质: ${C_BLUE}${attachable_material:=entity_alphatest_one_sided}
${C_GRAY}方块材质: ${C_BLUE}${block_material:=alpha_test}
${C_GRAY}后备包 URL: ${C_BLUE}${fallback_pack:=null}
"

# 解压我们的输入包
status_message process "正在解压输入包"
7z x -y "${1}" > /dev/null
status_message completion "输入包已解压"

# 如果没有输入包存在,通过检查 pack.mcmeta 文件退出脚本
if [ ! -f pack.mcmeta ]
then
	status_message error "无效的资源包! pack.mcmeta 文件不存在。资源包是否被错误地压缩在一个封闭的文件夹中?"
  exit 1
fi

# 确保包含谓词定义的目录存在
if test -d "./assets/minecraft/models/item"
then 
  status_message completion "已找到 Minecraft 命名空间物品文件夹。"
else
  # 为 bp 和 rp 创建初始目录
  status_message process "正在为我们的基岩版资源包生成初始目录结构"
  mkdir -p ./target/rp/models/blocks && mkdir -p ./target/rp/textures && mkdir -p ./target/rp/attachables && mkdir -p ./target/rp/animations && mkdir -p ./target/bp/blocks && mkdir -p ./target/bp/items

  # 如果我们有 pack.png,就复制它
  if test -f "./pack.png"; then
      cp ./pack.png ./target/rp/pack_icon.png && cp ./pack.png ./target/bp/pack_icon.png
  fi

  # 为我们的清单生成 UUID
  uuid1=($(uuidgen))
  uuid2=($(uuidgen))
  uuid3=($(uuidgen))
  uuid4=($(uuidgen))

  # 获取包描述
  pack_desc="$(jq -r '(.pack.description // "Geyser 3D 物品资源包(你没修改默认描述欸, 留个Ciallo~)")' ./pack.mcmeta)"

  # 生成 rp manifest.json
  status_message process "正在生成资源包清单"
  jq -c --arg pack_desc "${pack_desc}" --arg uuid1 "${uuid1}" --arg uuid2 "${uuid2}" -n '
  {
      "format_version": 2,
      "header": {
          "description": "添加用于 Geyser 代理的 3D 物品",
          "name": $pack_desc,
          "uuid": ($uuid1 | ascii_downcase),
          "version": [1, 0, 0],
          "min_engine_version": [1, 18, 3]
      },
      "modules": [
          {
              "description": "添加用于 Geyser 代理的 3D 物品",
              "type": "resources",
              "uuid": ($uuid2 | ascii_downcase),
              "version": [1, 0, 0]
          }
      ]
  }
  ' | sponge ./target/rp/manifest.json

  # 生成 bp manifest.json
  status_message process "正在生成行为包清单"
  jq -c --arg pack_desc "${pack_desc}" --arg uuid1 "${uuid1}" --arg uuid3 "${uuid3}" --arg uuid4 "${uuid4}" -n '
  {
      "format_version": 2,
      "header": {
          "description": "添加用于 Geyser 代理的 3D 物品",
          "name": $pack_desc,
          "uuid": ($uuid3 | ascii_downcase),
          "version": [1, 0, 0],
          "min_engine_version": [ 1, 18, 3]
      },
      "modules": [
          {
              "description": "添加用于 Geyser 代理的 3D 物品",
              "type": "data",
              "uuid": ($uuid4 | ascii_downcase),
              "version": [1, 0, 0]
          }
      ],
      "dependencies": [
          {
              "uuid": ($uuid1 | ascii_downcase),
              "version": [1, 0, 0]
          }
      ]
  }
  ' | sponge ./target/bp/manifest.json

  # 生成 rp terrain_texture.json
  status_message process "正在生成资源包地形纹理定义"
  jq -nc '
  {
    "resource_pack_name": "geyser_custom",
    "texture_name": "atlas.terrain",
    "texture_data": {
    }
  }
  ' | sponge ./target/rp/textures/terrain_texture.json

  # 生成 rp item_texture.json
  status_message process "正在生成资源包物品纹理定义"
  jq -nc '
  {
    "resource_pack_name": "geyser_custom",
    "texture_name": "atlas.items",
    "texture_data": {}
  }
  ' | sponge ./target/rp/textures/item_texture.json

  status_message process "正在生成资源包禁用动画"
  # 生成我们的禁用动画
  jq -nc '
  {
    "format_version": "1.8.0",
    "animations": {
      "animation.geyser_custom.disable": {
        "loop": true,
        "override_previous_animation": true,
        "bones": {
          "geyser_custom": {
            "scale": 0
          }
        }
      }
    }
  }
  ' | sponge ./target/rp/animations/animation.geyser_custom.disable.json
  cd -
  python manager.py
  cd ./staging
  # 清理
  rm -rf assets && rm -f pack.mcmeta && rm -f pack.png
  if [[ ${save_scratch} != "true" ]] 
  then
    rm -rf scratch_files
    status_message critical "已删除临时文件"
  else
    cd ./scratch_files > /dev/null && zip -rq8 scratch_files.zip . -x "*/.*" && cd .. > /dev/null && mv ./scratch_files/scratch_files.zip ./target/scratch_files.zip
    status_message completion "已归档临时文件\n"
  fi

  status_message process "正在压缩输出包"
  mkdir ./target/packaged
  cd ./target/rp > /dev/null && 7z a -tzip -mx=1 -mm=Deflate geyser_resources_preview.mcpack . -xr!.* > /dev/null && cd ../.. > /dev/null && mv ./target/rp/geyser_resources_preview.mcpack ./target/packaged/geyser_resources_preview.mcpack
  cd ./target/bp > /dev/null && 7z a -tzip -mx=1 -mm=Deflate geyser_behaviors_preview.mcpack . -xr!.* > /dev/null && cd ../.. > /dev/null && mv ./target/bp/geyser_behaviors_preview.mcpack ./target/packaged/geyser_behaviors_preview.mcpack
  cd ./target/packaged > /dev/null && 7z a -tzip -mx=1 -mm=Deflate geyser_addon.mcaddon *_preview.mcpack > /dev/null && cd ../.. > /dev/null
  jq 'delpaths([paths | select(.[-1] | strings | startswith("gmdl_atlas_"))])' ./target/rp/textures/terrain_texture.json | sponge ./target/rp/textures/terrain_texture.json
  cd ./target/rp > /dev/null && 7z a -tzip -mx=1 -mm=Deflate geyser_resources.mcpack . -xr!.* > /dev/null && cd ../.. > /dev/null && mv ./target/rp/geyser_resources.mcpack ./target/packaged/geyser_resources.mcpack
  mkdir ./target/unpackaged
  mv ./target/rp ./target/unpackaged/rp && mv ./target/bp ./target/unpackaged/bp

  echo
  printf "\e[32m[+]\e[m \e[1m\e[37m转换过程完成\e[m\n\n\e[37m正在退出...\e[m\n\n"