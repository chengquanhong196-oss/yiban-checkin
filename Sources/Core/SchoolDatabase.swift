import Foundation

// MARK: - 学校数据库（校名 + 校区 + 坐标 + 校本化参数）

public struct SchoolInfo: Identifiable, Hashable {
    public let id = UUID()
    public let name: String                // 学校名称
    public let campuses: [CampusInfo]      // 校区列表
    public let yibanAct: String            // 校本化 App ID
    public let yibanClientId: String       // OAuth Client ID

    public func hash(into hasher: inout Hasher) { hasher.combine(name) }
    public static func == (lhs: SchoolInfo, rhs: SchoolInfo) -> Bool { lhs.name == rhs.name }
}

public struct CampusInfo: Identifiable, Hashable {
    public let id = UUID()
    public let name: String
    public let latitude: Double
    public let longitude: Double
}

// MARK: - 数据库

public enum SchoolDatabase {
    /// 所有已收录的学校
    public static let schools: [SchoolInfo] = _build()

    /// 搜索学校（按名称模糊匹配）
    public static func search(_ query: String) -> [SchoolInfo] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return schools }
        return schools.filter { $0.name.contains(q) || $0.name.lowercased().contains(q.lowercased()) }
    }

    /// 按名称查找学校
    public static func find(name: String) -> SchoolInfo? {
        schools.first { $0.name == name }
    }

    // swiftlint:disable function_body_length
    private static func _build() -> [SchoolInfo] {
[
    // ── 福建 ──
    SchoolInfo(name: "福州大学", campuses: [
        CampusInfo(name: "旗山",   latitude: 26.0732, longitude: 119.1932),
        CampusInfo(name: "晋江",   latitude: 24.5580, longitude: 118.5874),
        CampusInfo(name: "铜盘",   latitude: 26.1043, longitude: 119.2800),
        CampusInfo(name: "集美",   latitude: 24.5910, longitude: 118.0970),
    ], yibanAct: "iapp7463", yibanClientId: "95626fa3080300ea"),

    SchoolInfo(name: "厦门大学", campuses: [
        CampusInfo(name: "思明",   latitude: 24.4393, longitude: 118.0893),
        CampusInfo(name: "翔安",   latitude: 24.6075, longitude: 118.3185),
        CampusInfo(name: "漳州",   latitude: 24.4265, longitude: 117.9790),
    ], yibanAct: "", yibanClientId: ""),

    SchoolInfo(name: "福建师范大学", campuses: [
        CampusInfo(name: "旗山",   latitude: 26.0415, longitude: 119.2073),
        CampusInfo(name: "仓山",   latitude: 26.0417, longitude: 119.3027),
    ], yibanAct: "", yibanClientId: ""),

    SchoolInfo(name: "福建农林大学", campuses: [
        CampusInfo(name: "金山",   latitude: 26.0847, longitude: 119.2330),
        CampusInfo(name: "旗山",   latitude: 26.0488, longitude: 119.1950),
    ], yibanAct: "", yibanClientId: ""),

    SchoolInfo(name: "华侨大学", campuses: [
        CampusInfo(name: "厦门",   latitude: 24.6060, longitude: 118.0828),
        CampusInfo(name: "泉州",   latitude: 24.8760, longitude: 118.5960),
    ], yibanAct: "", yibanClientId: ""),

    SchoolInfo(name: "集美大学", campuses: [
        CampusInfo(name: "主校区", latitude: 24.5856, longitude: 118.0997),
    ], yibanAct: "", yibanClientId: ""),

    // ── 北京 ──
    SchoolInfo(name: "北京大学", campuses: [
        CampusInfo(name: "燕园",   latitude: 39.9920, longitude: 116.3050),
    ], yibanAct: "", yibanClientId: ""),
    SchoolInfo(name: "清华大学", campuses: [
        CampusInfo(name: "主校区", latitude: 40.0070, longitude: 116.3240),
    ], yibanAct: "", yibanClientId: ""),
    SchoolInfo(name: "北京理工大学", campuses: [
        CampusInfo(name: "中关村", latitude: 39.9606, longitude: 116.3167),
        CampusInfo(name: "良乡",   latitude: 39.7320, longitude: 116.1430),
    ], yibanAct: "", yibanClientId: ""),

    // ── 上海 ──
    SchoolInfo(name: "复旦大学", campuses: [
        CampusInfo(name: "邯郸",   latitude: 31.2975, longitude: 121.4997),
        CampusInfo(name: "江湾",   latitude: 31.3397, longitude: 121.5070),
    ], yibanAct: "", yibanClientId: ""),
    SchoolInfo(name: "上海交通大学", campuses: [
        CampusInfo(name: "闵行",   latitude: 31.0250, longitude: 121.4365),
        CampusInfo(name: "徐汇",   latitude: 31.2000, longitude: 121.4320),
    ], yibanAct: "", yibanClientId: ""),
    SchoolInfo(name: "同济大学", campuses: [
        CampusInfo(name: "四平路", latitude: 31.2850, longitude: 121.4987),
        CampusInfo(name: "嘉定",   latitude: 31.2900, longitude: 121.2190),
    ], yibanAct: "", yibanClientId: ""),

    // ── 广东 ──
    SchoolInfo(name: "中山大学", campuses: [
        CampusInfo(name: "广州南", latitude: 23.0530, longitude: 113.3750),
        CampusInfo(name: "广州东", latitude: 23.1400, longitude: 113.2960),
        CampusInfo(name: "珠海",   latitude: 22.3550, longitude: 113.5610),
        CampusInfo(name: "深圳",   latitude: 22.5300, longitude: 113.9530),
    ], yibanAct: "", yibanClientId: ""),
    SchoolInfo(name: "华南理工大学", campuses: [
        CampusInfo(name: "五山",   latitude: 23.1530, longitude: 113.3400),
        CampusInfo(name: "大学城", latitude: 23.0530, longitude: 113.3950),
    ], yibanAct: "", yibanClientId: ""),
    SchoolInfo(name: "深圳大学", campuses: [
        CampusInfo(name: "粤海",   latitude: 22.5350, longitude: 113.9400),
        CampusInfo(name: "丽湖",   latitude: 22.5940, longitude: 113.9670),
    ], yibanAct: "", yibanClientId: ""),
    SchoolInfo(name: "暨南大学", campuses: [
        CampusInfo(name: "石牌",   latitude: 23.1280, longitude: 113.3480),
        CampusInfo(name: "番禺",   latitude: 23.0460, longitude: 113.3950),
        CampusInfo(name: "珠海",   latitude: 22.3510, longitude: 113.5540),
    ], yibanAct: "", yibanClientId: ""),

    // ── 浙江 ──
    SchoolInfo(name: "浙江大学", campuses: [
        CampusInfo(name: "紫金港", latitude: 30.3050, longitude: 120.0860),
        CampusInfo(name: "玉泉",   latitude: 30.2640, longitude: 120.1270),
        CampusInfo(name: "西溪",   latitude: 30.2760, longitude: 120.1370),
        CampusInfo(name: "之江",   latitude: 30.2150, longitude: 120.1230),
    ], yibanAct: "", yibanClientId: ""),

    // ── 湖北 ──
    SchoolInfo(name: "武汉大学", campuses: [
        CampusInfo(name: "主校区", latitude: 30.5410, longitude: 114.3630),
    ], yibanAct: "", yibanClientId: ""),
    SchoolInfo(name: "华中科技大学", campuses: [
        CampusInfo(name: "主校区", latitude: 30.5140, longitude: 114.4160),
    ], yibanAct: "", yibanClientId: ""),

    // ── 四川/重庆 ──
    SchoolInfo(name: "四川大学", campuses: [
        CampusInfo(name: "望江",   latitude: 30.6290, longitude: 104.0800),
        CampusInfo(name: "江安",   latitude: 30.5570, longitude: 103.9930),
    ], yibanAct: "", yibanClientId: ""),
    SchoolInfo(name: "重庆大学", campuses: [
        CampusInfo(name: "A区",    latitude: 29.5670, longitude: 106.4680),
        CampusInfo(name: "虎溪",   latitude: 29.5960, longitude: 106.3080),
    ], yibanAct: "", yibanClientId: ""),

    // ── 江苏 ──
    SchoolInfo(name: "南京大学", campuses: [
        CampusInfo(name: "仙林",   latitude: 32.1170, longitude: 118.9580),
        CampusInfo(name: "鼓楼",   latitude: 32.0580, longitude: 118.7800),
    ], yibanAct: "", yibanClientId: ""),
    SchoolInfo(name: "东南大学", campuses: [
        CampusInfo(name: "九龙湖", latitude: 31.8880, longitude: 118.8250),
        CampusInfo(name: "四牌楼", latitude: 32.0550, longitude: 118.7920),
    ], yibanAct: "", yibanClientId: ""),

    // ── 其他 ──
    SchoolInfo(name: "中国科学技术大学", campuses: [
        CampusInfo(name: "东区",   latitude: 31.8350, longitude: 117.2710),
        CampusInfo(name: "西区",   latitude: 31.8330, longitude: 117.2580),
    ], yibanAct: "", yibanClientId: ""),
    SchoolInfo(name: "西安交通大学", campuses: [
        CampusInfo(name: "兴庆",   latitude: 34.2460, longitude: 108.9870),
        CampusInfo(name: "雁塔",   latitude: 34.2210, longitude: 108.9870),
    ], yibanAct: "", yibanClientId: ""),
    SchoolInfo(name: "哈尔滨工业大学", campuses: [
        CampusInfo(name: "主校区", latitude: 45.7460, longitude: 126.6340),
        CampusInfo(name: "深圳",   latitude: 22.5900, longitude: 113.9570),
        CampusInfo(name: "威海",   latitude: 37.5310, longitude: 122.0730),
    ], yibanAct: "", yibanClientId: ""),
]
    }
}
