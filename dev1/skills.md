开发功能时只写入需求提到的功能，而不需要额外添加辅助功能或改进功能

卡牌系统：
- test_card.js：定义卡牌数组testCards，包含blanket(cost:1, health:1, attack:1, type:单位)和pro(cost:2, health:2, attack:2, type:单位)
- getRandomCard()函数：从testCards数组中随机抽取一张卡牌
- 玩家手牌使用addCard()生成随机卡牌
- 卡牌显示：右上角显示cost(蓝色圆形)，中间显示name，左下角显示attack(红色)，右下角显示health(绿色)

格子系统：
- 格子大小自适应，保持正方形
- 有卡牌的格子添加has-card类，显示黑色边框
- 敌方格子添加enemy-card类，灰色背景(#999)
- 格子内显示：cell-text(名称)，cell-attack(左下角红色)，cell-health(右下角绿色)

移动动画：
- createMovingCard()：创建临时移动卡牌，isEnemy参数控制背景颜色(灰色/白色)
- animateCardMove()：线性插值动画，移动时保留攻击力和血量数据
- 敌人移动时背景保持灰色

回合系统(endTurn)：
- 玩家移动：遍历row 0→5，col 0→2，从上往下从左往右
- 敌人移动：遍历row 5→0，col 2→0，从下往上从右往左
- 移动条件：前方有空格则移动一格，最前方不移动
- 移动顺序：玩家全部移动完后，敌人才移动
- 每移动一个棋子后等待500ms
- 回合按钮：点击后禁用按钮，文字变为"行动中..."，按钮变灰，行动完成后恢复

初始化：
- test_level_config.js：UNIT_CONFIG数组定义单位配置，name为卡牌名，faction为阵营(0己方/1敌方)，positions为坐标数组
- initUnits()函数：根据UNIT_CONFIG在游戏开始时放置单位到对应位置
- 敌方单位标记data-is-enemy="true"

放置限制：
- 单位卡牌只能放置在己方半场(row 3-5)
- 单位卡牌拖拽到敌方半场(row 0-2)时，鼠标显示禁止图标，无法放置
