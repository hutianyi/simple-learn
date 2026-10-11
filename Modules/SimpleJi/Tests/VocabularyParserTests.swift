import XCTest
@testable import WordMemoryCards

final class VocabularyParserTests: XCTestCase {
    func testSupportedFormatsAndIgnoredMarkdown() {
        let input = """
        # Unit 1
        apple 苹果
        Apple    苹果
        - banana 香蕉
        * orange 橙子
        ice cream 冰淇淋
        look after\t照顾
        can't - 不能
        can’t — 不能
        ---

        wrong line
        """

        let result = VocabularyParser.parse(input)

        XCTAssertEqual(result.entries.count, 8)
        XCTAssertEqual(result.unrecognized.count, 1)
        XCTAssertEqual(result.entries[4].english, "ice cream")
        XCTAssertEqual(result.entries[5].english, "look after")
        XCTAssertEqual(result.entries[6].normalizedEnglish, "can't")
        XCTAssertEqual(result.entries[7].normalizedEnglish, "can't")
        XCTAssertEqual(result.unrecognized.first?.text, "wrong line")
    }

    func testEnglishNormalizationPreservesMeaningfulPunctuation() {
        XCTAssertEqual(EnglishNormalizer.normalize("  ICE   CREAM  "), "ice cream")
        XCTAssertEqual(EnglishNormalizer.normalize("can’t"), "can't")
        XCTAssertEqual(EnglishNormalizer.normalize("mother-in-law"), "mother-in-law")
    }

    func testInvalidSidesAreRejected() {
        let result = VocabularyParser.parse("123 苹果\napple 123")

        XCTAssertTrue(result.entries.isEmpty)
        XCTAssertEqual(result.unrecognized.count, 2)
    }

    func testPartOfSpeechBelongsToMeaningAcrossImportFormats() {
        for input in ["conversation n.对话", "conversation n. 对话", "conversation n.\t对话",
                      "conversation n. - 对话", "conversation — n.对话", "conversation\tn.对话"] {
            let result = VocabularyParser.parse(input)
            XCTAssertTrue(result.unrecognized.isEmpty, input)
            XCTAssertEqual(result.entries.first?.english, "conversation", input)
            XCTAssertEqual(result.entries.first?.normalizedEnglish, "conversation", input)
            XCTAssertEqual(result.entries.first?.chinese, "n.对话", input)
            if let entry = result.entries.first {
                XCTAssertTrue(DictationAnswerMatcher.matches("conversation", answer: entry.english), input)
                XCTAssertFalse(DictationAnswerMatcher.matches("conversation n.", answer: entry.english), input)
            }
        }
    }

    func testCommonAndCombinedPartOfSpeechLabels() {
        for label in ["n.", "v.", "vt.", "vi.", "adj.", "adv.", "pron.", "prep.", "conj.",
                      "interj.", "num.", "art.", "n./v.", "vt. & vi."] {
            let result = VocabularyParser.parse("test \(label) 测试")
            XCTAssertEqual(result.entries.first?.english, "test", label)
            XCTAssertEqual(result.entries.first?.chinese, label + "测试", label)
        }
    }

    func testParenthesizedMeaningStaysOutOfEnglish() {
        let examples = [
            ("actor n.（男）演员", "actor", "n.（男）演员"),
            ("actor n.(男)演员", "actor", "n.(男)演员"),
            ("actor N. （ 男 ）演员", "actor", "N.（ 男 ）演员"),
            ("actor（男）演员", "actor", "（男）演员"),
            ("actor (男)演员", "actor", "(男)演员"),
            ("actor n.（（男）演员）", "actor", "n.（（男）演员）"),
            ("actor n./v.（男）演员", "actor", "n./v.（男）演员"),
            ("actor n.\t（男）演员", "actor", "n.（男）演员"),
            ("actor n. - （男）演员", "actor", "n.（男）演员"),
            ("actor — n.（男）演员", "actor", "n.（男）演员"),
            ("actor\tn.（男）演员", "actor", "n.（男）演员"),
            ("sing v. 唱（歌）", "sing", "v.唱（歌）"),
            ("DVD player DVD 播放器", "DVD player DVD", "播放器"),
            ("word(s) n.（多个）单词", "word(s)", "n.（多个）单词"),
            ("colour (UK) n.（一种）颜色", "colour (UK)", "n.（一种）颜色")
        ]
        for (input, english, chinese) in examples {
            let result = VocabularyParser.parse(input)
            XCTAssertTrue(result.unrecognized.isEmpty, input)
            XCTAssertEqual(result.entries.count, 1, input)
            XCTAssertEqual(result.entries.first?.english, english, input)
            XCTAssertEqual(result.entries.first?.normalizedEnglish, EnglishNormalizer.normalize(english), input)
            XCTAssertEqual(result.entries.first?.chinese, chinese, input)
            if let entry = result.entries.first {
                XCTAssertTrue(DictationAnswerMatcher.matches(english, answer: entry.english), input)
            }
        }
    }

    func testArtVocabularyBatchWithParentheses() {
        let input = """
        draw v. 绘画
        actor n.（男）演员
        drawing n. 绘画；图画
        programme n. 程序；计划；节目
        adventure n. 冒险
        disco n. 迪斯科舞厅
        museum n. 博物馆
        drum n. 鼓
        music n. 音乐
        art n. 艺术
        DVD player DVD 播放器
        musician n. 音乐家
        exhibition n. 展览
        news n. 新闻报道
        rock n. 岩石；摇滚乐
        boardgame n. 棋类游戏
        festival n. 节日；音乐节
        film n. 电影 v. 拍摄电影
        opera n. 歌剧
        show n. 演出；节目
        fun adj. 有趣的
        paint v. 用颜料画；粉刷
        sing v. 唱（歌）
        cartoon n. 卡通片；动画片
        journalist n. 新闻记者
        """
        let result = VocabularyParser.parse(input)
        XCTAssertTrue(result.unrecognized.isEmpty)
        XCTAssertEqual(result.entries.map(\.english), [
            "draw", "actor", "drawing", "programme", "adventure", "disco", "museum",
            "drum", "music", "art", "DVD player DVD", "musician", "exhibition", "news",
            "rock", "boardgame", "festival", "film", "opera", "show", "fun", "paint",
            "sing", "cartoon", "journalist"
        ])
        XCTAssertEqual(result.entries.map(\.chinese), [
            "v.绘画", "n.（男）演员", "n.绘画；图画", "n.程序；计划；节目", "n.冒险",
            "n.迪斯科舞厅", "n.博物馆", "n.鼓", "n.音乐", "n.艺术", "播放器", "n.音乐家",
            "n.展览", "n.新闻报道", "n.岩石；摇滚乐", "n.棋类游戏", "n.节日；音乐节",
            "n.电影 v. 拍摄电影", "n.歌剧", "n.演出；节目", "adj.有趣的",
            "v.用颜料画；粉刷", "v.唱（歌）", "n.卡通片；动画片", "n.新闻记者"
        ])
    }

    func testPartOfSpeechDoesNotStripPhrasesOrOtherAbbreviations() {
        for term in ["ice cream", "look after", "vitamin B", "U.S.", "plan.", "a", "chapter no."] {
            let result = VocabularyParser.parse("\(term) 释义")
            XCTAssertEqual(result.entries.first?.english, term)
            XCTAssertEqual(result.entries.first?.chinese, "释义")
        }
        XCTAssertEqual(VocabularyParser.parse("n. 名词").unrecognized.count, 1)
    }

    func testChineseSpeechSkipsCommonPartOfSpeechLabels() {
        for label in ["n.", "N.", "v.", "vt.", "vi.", "adj.", "ADJ", "adv.", "pron.",
                      "prep.", "conj.", "interj.", "int.", "num.", "art.", "det.", "aux.",
                      "modal.", "abbr.", "phr.", "n./v.", "vt. & vi.", "n.、v.", "n．",
                      "noun", "adjective", "verb", "ADVERB:"] {
            XCTAssertEqual(VocabularyParser.chineseMeaningForSpeech(label + "化学"), "化学", label)
            XCTAssertEqual(VocabularyParser.chineseMeaningForSpeech("  " + label + " 化学  "), "化学", label)
        }
    }

    func testChineseSpeechSkipsLabelsAcrossMultipleMeanings() {
        let examples = [
            ("n.计划；v.打算", "计划；打算"),
            ("adj.漂亮的，adv.漂亮地", "漂亮的，漂亮地"),
            ("noun:计划; verb:打算", "计划;打算"),
            ("n.计划\nv.打算", "计划\n打算"),
            ("（adj.漂亮的）", "（漂亮的）"),
            ("n. vitamin B，维生素B", "vitamin B，维生素B")
        ]
        for (meaning, spoken) in examples {
            XCTAssertEqual(VocabularyParser.chineseMeaningForSpeech(meaning), spoken, meaning)
        }
    }

    func testChineseSpeechPreservesOrdinaryEnglishAndUnknownLabels() {
        for meaning in ["化学", "维生素B", "DNA分子", "N95口罩", "Vitamin B：维生素B",
                        "U.S.美国", "No.编号", "形容词 adjective 表示性质", "nav.导航",
                        "nounphrase 名词短语", "noun phrase：名词短语", "verb describes an action：动词",
                        "https://example.com 示例网站"] {
            XCTAssertEqual(VocabularyParser.chineseMeaningForSpeech(meaning), meaning)
        }
    }
}
