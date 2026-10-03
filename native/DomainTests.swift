import Foundation

@main struct Tests {
    static func main() throws {
        let v = Variant(partNumber:"DEMO1/A",family:"test",selections:["color":"black"],label:"黑色",url:"https://www.apple.com.cn/shop/product/demo1/a",price:100,comingSoon:false)
        let c = Catalog(source:v.url,title:"test",groups:[Group(key:"color",title:"颜色",options:[Option(value:"black",label:"黑色")])],variants:[v])
        assert(c.resolve([:]) == nil)
        assert(c.resolve(["color":"black"])?.partNumber == "DEMO1/A")
        assert(c.resolve(["color":"white"]) == nil)
        assert(!officialProductURL("https://www.apple.com.cn.evil.example/shop/test"))
        assert(!officialProductURL("https://secret@www.apple.com.cn/shop/test"))
        assert(!officialProductURL("https://www.apple.com.cn/shop/test?token=secret"))
        assert(isManagedAccountPage("https://www.apple.com.cn/shop/account/home"))
        assert(isManagedAccountPage("https://www.apple.com.cn/shop/signin"))
        assert(!isManagedAccountPage("https://www.apple.com.cn/shop/buy-iphone/iphone-duo"))
        assert(!isManagedAccountPage("https://www.apple.com.cn.evil.example/shop/account/home"))
        let orderedIDs = ["duo-512", "pro-256", "max-1tb"]
        assert(planIDForPresetIndex(0, orderedIDs: orderedIDs) == nil)
        assert(planIDForPresetIndex(2, orderedIDs: orderedIDs) == "pro-256")
        assert(planIDForPresetIndex(4, orderedIDs: orderedIDs) == nil)
        var p = Plan(name:"test",source:v.url,variant:v,catalogHash:c.hash,releaseAt:Date().addingTimeInterval(60))
        assert(p.quietSeconds == 60)
        assert(managedPreparationInterval(remaining: 30, quietSeconds: 60, configurationReady: false) == 0.2)
        assert(managedPreparationInterval(remaining: 30, quietSeconds: 60, configurationReady: true) == nil)
        assert(managedPreparationInterval(remaining: 90, quietSeconds: 60, configurationReady: true) == 1.0)
        assert(managedPreparationInterval(remaining: 5, quietSeconds: 60, configurationReady: true) == 0.05)
        assert(managedPreparationInterval(remaining: 0, quietSeconds: 60, configurationReady: true) == nil)
        let boundary = ISO8601DateFormatter().date(from: "2026-10-01T00:00:30Z")!
        let times = managedScheduleTimes(releaseAt: boundary, prepareSeconds: 300, quietSeconds: 60, executionSeconds: 60)
        assert(ISO8601DateFormatter().string(from: times.preparationStarts) == "2026-09-30T23:55:30Z")
        assert(ISO8601DateFormatter().string(from: times.quietStarts) == "2026-09-30T23:59:30Z")
        assert(ISO8601DateFormatter().string(from: times.executionStarts) == "2026-10-01T00:00:30Z")
        assert(ISO8601DateFormatter().string(from: times.executionEnds) == "2026-10-01T00:01:30Z")
        assert(addAttemptWasNotIssued("disabled"))
        assert(addAttemptWasNotIssued("missing"))
        assert(!addAttemptWasNotIssued("clicked"))
        assert(!addAttemptWasNotIssued("unknown"))
        try p.validate(now:Date())
        p.releaseAt = Date().addingTimeInterval(-1)
        do { try p.validate(now:Date()); fatalError("past time accepted") } catch {}
        p.releaseAt = Date().addingTimeInterval(60); p.autoSubmit = true
        do { try p.validate(now:Date()); fatalError("missing submit accepted") } catch {}
        p.autoSubmit = false
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = try Storage(root:dir)
        let config = ProductPlan(p)
        try config.validate()
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let configJSON = try JSONSerialization.jsonObject(with: encoder.encode(config)) as! [String: Any]
        for key in ["releaseAt", "prepareSeconds", "quietSeconds", "executionSeconds", "autoSubmit", "actions"] {
            assert(configJSON[key] == nil, "Product configuration retained execution field: \(key)")
        }
        var legacy = p; legacy.releaseAt = Date().addingTimeInterval(-3600)
        let migrated = try decoder.decode(ProductPlan.self, from: encoder.encode(legacy))
        try migrated.validate()
        assert(migrated.id == p.id && migrated.variant.partNumber == p.variant.partNumber)
        let currentTime = Date().addingTimeInterval(120)
        let task = migrated.executionPlan(releaseAt: currentTime)
        assert(task.releaseAt == currentTime)
        try task.validate(now: Date())
        do { try migrated.executionPlan(releaseAt: legacy.releaseAt).validate(now: Date()); fatalError("past task time accepted") } catch {}
        try store.write(Saved(plans:[config],selectedID:p.id),"plans.json")
        let roundtrip = try store.read("plans.json",as:Saved.self)!
        assert(roundtrip.plans[0].variant.partNumber == p.variant.partNumber)
        // Existing saved files decode as product configurations despite expired dates.
        let legacySaved = try JSONSerialization.data(withJSONObject: ["plans": [try JSONSerialization.jsonObject(with: encoder.encode(legacy))], "selectedID": p.id])
        let migratedSaved = try decoder.decode(Saved.self, from: legacySaved)
        assert(migratedSaved.plans[0].id == p.id)
        var run = RunRecord(plan:p); run.attempted = [0]; run.state = "manual"
        try store.write(run,"run.json")
        let restored = try store.read("run.json",as:RunRecord.self)!
        assert(restored.attempted == [0])
        print("Domain tests passed: product-only persistence and legacy migration; execution uses current time and rejects past time; configuration, origin, submit requirements, attempt recovery")
    }
}
