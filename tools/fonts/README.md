# 标题字体与字表

- 上游：[LXGW WenKai v1.530](https://github.com/lxgw/LxgwWenKai/releases/tag/v1.530)，Regular；许可证原文见 `docs/licenses/LXGWWenKai-OFL.txt`。
- 原始 TTF SHA256：`2d73eea94ad808999d90c0000c239a84a33b09d4bc6ab6c5b8bbf1eda8a7fc8b`。
- `charset.txt` 包含《通用规范汉字表》一、二级共 6500 字（含扩展区汉字），外加 ASCII、中文标点和界面符号；字表数字化来源：[level-1.txt](https://github.com/shengdoushi/common-standard-chinese-characters-table/blob/master/level-1.txt)、[level-2.txt](https://github.com/shengdoushi/common-standard-chinese-characters-table/blob/master/level-2.txt)。字表已随仓库固定，重建无需下载字表。
- 构建工具：`server/.venv/Scripts/python.exe -m pip install -r tools/requirements-assets.txt`；然后 `python tools/subset-fonts.py <原始TTF路径>`。不要向研究 Python 环境安装依赖。
- 修改后的字体重命名为 **Planner WenKai**，应用注册名 `WenKai`，保留上游版权、许可证与生僻字系统回落。产物 3,316,456 字节。
- `python tools/gen-paper-texture.py` 生成固定随机种子、可平铺的 256px 纸纹，33,157 字节。减少动画时客户端关闭纹理。
