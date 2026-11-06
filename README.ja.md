# Crank Reel

[English](README.md)

Crank Reelは、Playdateのクランクで上映するドットアニメ工房です。16×16の白黒キャンバスに最大32コマを描けます。クランクを速く回すと絵と音楽が速く進み、逆に回すと巻き戻ります。手を止めれば、そのコマで止まります。

![フィルムと手回し映写機を描いたCrank Reelのバナー](Source/launcher/card.png)

## インストール

このリポジトリの **Releases → Assets** から `CrankReel.pdx.zip` をダウンロードします。[PlaydateのSideloadページ](https://play.date/account/sideload/)でZIPをアップロードし、本体のゲームライブラリからCrank Reelを開きます。USBでのインストールや一覧の更新方法は[公式のSideloadガイド](https://help.play.date/ja/games/sideloading/)を参照してください。

Playdate Simulatorでは、ZIPを解凍し、**File → Open** で `CrankReel.pdx` を開きます。

## 作って上映する

1. タイトル画面で **A** を押して作品棚へ。**New reel** で新規作成するか、**Jellyfish** でクランク上映を試せます。
2. 工房では十字キーでカーソルを動かし、**A** でドットを反転します。クランクでコマを選び、**B** で **Film strip**、**Generate motion**、**Save reel** などのツールを開きます。
3. **Screen this reel** で上映します。クランクまたは左右でコマを送り、**A** でループを切り替え、**B** で戻ります。作品棚では **右** で編集、**左** でタイトル画面に戻ります。

Jellyfishで **右** を押すと編集用コピーを開きます。見本でもBGMとループ設定は変更できます。旧版で見本のコマを編集していた場合は **B → Restore sample (keep backup)** で元のコマに戻し、編集済みの作品を別リールとして残せます。

**Film strip** では、移動したいコマを **A** でつかみ、移動先で再度 **A** を押します。**上** で直前の編集を取り消せます。**Frame hold** でコマに割り当てるクランク角度を1〜4倍に変更できます。**In-between frames** は、同じ形の絵が異なる位置にある隣り合う2コマから、移動の途中を生成します。

作品棚でリールを選んで **B** を押すと、複製やBGMの変更ができます。BGMは **Popcorn**、**Moon Drift**、**Dark Alley**、**Flash Bang** の4曲です。自作リールはタイトル変更と削除もできます。

## 作品を共有する

1. リールを選んで **B → Export reel code** を開きます。Crank Reelのセーブデータフォルダに `Export.crankreel` ができます。次の書き出しで上書きされるので、必要なファイルを取り出してください。
2. ファイル、または `CR1-` から始まるテキストを共有します。受け取った側は `Import.crankreel` という名前のプレーンテキストファイルにして、Crank Reelのセーブデータフォルダに置きます。
3. 作品棚で **New reel** を選んで **B** を押します。タイトルと先頭コマを確認し、**A** で別作品として追加します。

実機では、一度アプリを起動してから、USBのData Diskモードで `PLAYDATE/Data/` 内にあるCrank Reelのフォルダを開きます。Simulatorでは **File → Reveal Data folder** を使います。共有コードには作品名・コマ・ループ・「間」・BGMが含まれます。BOM付きUTF-8のテキストも読み込めます。

## ソースからビルド

[Playdate SDK](https://play.date/dev/)をインストールし、`pdc` にPATHを通します。リポジトリのルートで以下を実行します。

```sh
pdc Source CrankReel.pdx
```

出力された `CrankReel.pdx` をSimulatorで開くか、実機にインストールします。v0.8.2はSDK 3.1.2でビルドしました。

## テスト

Lua 5.3以降を使い、リポジトリのルートで `lua tests/reel_code.lua` を実行します。

## クレジットとライセンス

Crank Reel本体は [MITライセンス](LICENSE) です。第三者素材の表記は [NOTICE.md](NOTICE.md#日本語) を参照してください。
