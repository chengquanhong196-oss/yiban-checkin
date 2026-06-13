import SwiftUI
import YibanCheckinCore

// MARK: - 学校选择器（点击 → 弹出搜索列表 → 选校 → 选区 → 自动填坐标）

struct SchoolPicker: View {
    @Binding var schoolName: String
    @Binding var campusName: String
    @Binding var lat: String
    @Binding var lng: String
    @Binding var act: String
    @Binding var clientId: String

    @State private var selectedSchool: SchoolInfo?
    @State private var showSchoolList = false
    @State private var searchText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // ── 学校（点击弹出搜索） ──
            VStack(alignment: .leading, spacing: 4) {
                Text("学校").font(.caption).foregroundColor(.secondary)
                Button(action: { searchText = ""; showSchoolList = true }) {
                    HStack {
                        Text(schoolName.isEmpty ? "点击选择学校" : schoolName).font(.callout)
                            .foregroundColor(schoolName.isEmpty ? .secondary : .primary)
                        Spacer()
                        Image(systemName: "magnifyingglass").font(.caption).foregroundColor(.secondary)
                    }
                    .padding(10)
                    .background(.quaternary)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
            }
            .sheet(isPresented: $showSchoolList) {
                SchoolSearchSheet(
                    selectedSchool: $selectedSchool,
                    schoolName: $schoolName,
                    campusName: $campusName,
                    lat: $lat, lng: $lng,
                    act: $act, clientId: $clientId
                )
            }

            // ── 校区选择 ──
            if selectedSchool != nil {
                VStack(alignment: .leading, spacing: 4) {
                    Text("校区").font(.caption).foregroundColor(.secondary)
                    if let school = selectedSchool {
                        if school.campuses.isEmpty {
                            TextField("校区名称", text: $campusName).textFieldStyle(.roundedBorder)
                        } else if school.campuses.count == 1 && campusName == school.campuses[0].name {
                            HStack {
                                Text(school.campuses[0].name).font(.callout)
                                Spacer()
                                Image(systemName: "checkmark.circle.fill").foregroundColor(.green).font(.caption)
                                Button("手动输入") { campusName = ""; lat = ""; lng = "" }.buttonStyle(.link).font(.caption2)
                            }
                            .padding(10).background(.quaternary).clipShape(RoundedRectangle(cornerRadius: 6))
                            .onAppear { selectCampus(school.campuses[0]) }
                        } else {
                            HStack(spacing: 8) {
                                Menu {
                                    ForEach(school.campuses) { campus in
                                        Button(campus.name) { selectCampus(campus) }
                                    }
                                    Divider()
                                    Button("手动输入") { campusName = ""; lat = ""; lng = "" }
                                } label: {
                                    HStack {
                                        Text(campusName.isEmpty ? "选择校区" : campusName).font(.callout)
                                        Spacer()
                                        Image(systemName: "chevron.up.chevron.down").font(.caption).foregroundColor(.secondary)
                                    }
                                    .padding(10).background(.quaternary).clipShape(RoundedRectangle(cornerRadius: 6))
                                }
                                .buttonStyle(.plain)

                                if campusName.isEmpty || !school.campuses.contains(where: { $0.name == campusName }) {
                                    TextField("手动输入校区", text: $campusName)
                                        .textFieldStyle(.roundedBorder)
                                }
                            }
                        }
                    }
                }
            }

            // ── 坐标（选了校区后显示，数据库没有的留空自己填） ──
            if selectedSchool != nil && !campusName.isEmpty {
                let isFromDB = selectedSchool?.campuses.contains(where: { $0.name == campusName }) ?? false
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("纬度").font(.caption).foregroundColor(.secondary)
                        TextField(isFromDB ? "自动填入" : "手动输入", text: $lat).textFieldStyle(.roundedBorder)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("经度").font(.caption).foregroundColor(.secondary)
                        TextField(isFromDB ? "自动填入" : "手动输入", text: $lng).textFieldStyle(.roundedBorder)
                    }
                }
            }

            // ── 校本化参数状态 ──
            if selectedSchool != nil && act.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.caption).foregroundColor(.orange)
                    Text("需要填写校本化参数").font(.caption).foregroundColor(.secondary)
                }
            }
        }
    }

    private func selectCampus(_ campus: CampusInfo) {
        campusName = campus.name
        lat = String(format: "%.4f", campus.latitude)
        lng = String(format: "%.4f", campus.longitude)
    }
}

// MARK: - 学校搜索 Sheet

struct SchoolSearchSheet: View {
    @Binding var selectedSchool: SchoolInfo?
    @Binding var schoolName: String
    @Binding var campusName: String
    @Binding var lat: String; @Binding var lng: String
    @Binding var act: String; @Binding var clientId: String
    @Environment(\.dismiss) var dismiss
    @State private var query = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // 搜索栏
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                TextField("搜索学校名称…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.body)
                    .focused($isFocused)
                if !query.isEmpty {
                    Button(action: { query = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary).font(.body)
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 4)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary))
            .padding(.horizontal, 16).padding(.top, 16)

            // 结果列表
            let results = query.isEmpty ? SchoolDatabase.schools : SchoolDatabase.search(query)
            List(Array(results.enumerated()), id: \.element.name) { _, school in
                Button(action: { select(school) }) {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(school.name).font(.body).fontWeight(.medium)
                                .foregroundColor(.primary)
                            if !school.campuses.isEmpty {
                                Text(school.campuses.map(\.name).joined(separator: "、"))
                                    .font(.caption).foregroundColor(.secondary)
                            }
                        }
                        Spacer()
                        if school.name == selectedSchool?.name {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.accentColor).font(.title3)
                        }
                    }
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)

            if results.isEmpty {
                Spacer()
                Text("未找到匹配的学校").foregroundColor(.secondary).padding(32)
                Spacer()
            }

            // 取消按钮
            Divider()
            HStack {
                Spacer()
                Button("取消") { dismiss() }.buttonStyle(.bordered).controlSize(.large).padding(12)
            }
        }
        .frame(width: 420, height: 420)
        .onAppear { }
        .onDisappear { isFocused = false }
    }

    private func select(_ school: SchoolInfo) {
        selectedSchool = school
        schoolName = school.name
        act = school.yibanAct
        clientId = school.yibanClientId
        if school.campuses.count == 1 {
            campusName = school.campuses[0].name
            lat = String(format: "%.4f", school.campuses[0].latitude)
            lng = String(format: "%.4f", school.campuses[0].longitude)
        } else {
            campusName = ""
            lat = ""; lng = ""
        }
        dismiss()
    }
}
