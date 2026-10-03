import Foundation
import Darwin
import JavaScriptCore

@main struct BrowserControllerTests {
    @MainActor static func main() throws {
        let profile = FileManager.default.temporaryDirectory.appendingPathComponent("asa-profile-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: profile) }
        let lock = profile.appendingPathComponent("SingletonLock")

        assert(activeManagedBrowserProfilePID(profile) == nil)
        try FileManager.default.createSymbolicLink(at: lock, withDestinationURL: URL(fileURLWithPath: "test-host-\(getpid())"))
        assert(activeManagedBrowserProfilePID(profile) == getpid())

        try FileManager.default.removeItem(at: lock)
        try FileManager.default.createSymbolicLink(at: lock, withDestinationURL: URL(fileURLWithPath: "test-host-2147483647"))
        assert(activeManagedBrowserProfilePID(profile) == nil)

        let js = JSContext()!
        js.evaluateScript("""
        var location = {host:'www.apple.com.cn', hostname:'www.apple.com.cn', pathname:'/shop/product/demo1/a'};
        function URL(value) { var match = value.match(/^https?:\\/\\/([^/]+)(\\/.*)$/); return {host:match[1],pathname:match[2]}; }
        var clicks = 0;
        var window = {__asaClickCount:0};
        var button = {offsetWidth:1,offsetHeight:0,disabled:true,getClientRects:function(){return [];},getAttribute:function(){return null;},click:function(){clicks++;}};
        var document = {querySelector:function(){return button;},querySelectorAll:function(){return [];}};
        """)
        let click = try BrowserController.clickExpression(selector: "button[data-autom=add-to-cart]", expectedURL: "https://www.apple.com.cn/shop/product/demo1/a")
        assert(js.evaluateScript(click)?.toDictionary()?["state"] as? String == "disabled")
        assert(js.evaluateScript("clicks")?.toInt32() == 0)
        js.evaluateScript("button.disabled=false")
        assert(js.evaluateScript(click)?.toDictionary()?["state"] as? String == "clicked")
        assert(js.evaluateScript("clicks")?.toInt32() == 1)
        js.evaluateScript("location.pathname='/shop/product/other/a'")
        assert(js.evaluateScript(click)?.toDictionary()?["state"] as? String == "mismatch")
        assert(js.evaluateScript("clicks")?.toInt32() == 1)

        js.evaluateScript("""
        location.pathname='/shop/product/demo1/a';location.href='https://www.apple.com.cn/shop/product/demo1/a';
        button.disabled=true;
        var noTradeIn = {checked:true,disabled:false,click:function(){this.checked=true;}};
        var noCare = {checked:true,disabled:false,click:function(){this.checked=true;}};
        var continueButton = {disabled:true,offsetWidth:1,offsetHeight:0,getClientRects:function(){return [];},getAttribute:function(){return null;},click:function(){clicks++;}};
        document.querySelector=function(selector){
          if (selector.includes('noTradeIn')) return noTradeIn;
          if (selector.includes('noapplecare')) return noCare;
          if (selector.includes('add-to-cart')) return button;
          if (selector.includes('continueButton')) return continueButton;
          return null;
        };
        """)
        let preparation = BrowserController.productPreparationExpression()
        let beforeRelease = js.evaluateScript(preparation)?.toDictionary()
        assert(beforeRelease?["state"] as? String == "waiting")
        assert(beforeRelease?["noTradeIn"] as? Bool == true)
        assert(beforeRelease?["noAppleCare"] as? Bool == true)
        assert(beforeRelease?["addAvailable"] as? Bool == false)
        assert(beforeRelease?["addPresent"] as? Bool == true)
        assert(beforeRelease?["addDisabled"] as? Bool == true)
        assert(beforeRelease?["continuePresent"] as? Bool == true)
        assert(beforeRelease?["continueDisabled"] as? Bool == true)
        js.evaluateScript("button.disabled=false")
        let afterRelease = js.evaluateScript(preparation)?.toDictionary()
        assert(afterRelease?["state"] as? String == "ready")

        // Real pre-order markup can expose Continue without Add to Bag.
        js.evaluateScript("button.disabled=true;continueButton.disabled=false;document.querySelector=function(selector){if(selector.includes('noTradeIn'))return noTradeIn;if(selector.includes('noapplecare'))return noCare;if(selector.includes('add-to-cart'))return null;if(selector.includes('continueButton'))return continueButton;return null;}")
        let preorderRelease = js.evaluateScript(preparation)?.toDictionary()
        assert(preorderRelease?["state"] as? String == "ready")
        assert(preorderRelease?["phase"] as? String == "continue")
        let productAction = try BrowserController.productActionExpression(expectedURL: "https://www.apple.com.cn/shop/product/demo1/a")
        let beforeContinueClicks = js.evaluateScript("clicks")?.toInt32() ?? 0
        js.evaluateScript("noCare.checked=false")
        assert(js.evaluateScript(productAction)?.toDictionary()?["state"] as? String == "disabled")
        assert(js.evaluateScript("clicks")?.toInt32() == beforeContinueClicks)
        js.evaluateScript("noCare.checked=true")
        let continueResult = js.evaluateScript(productAction)?.toDictionary()
        assert(continueResult?["state"] as? String == "clicked")
        assert(continueResult?["kind"] as? String == "continue")
        assert(js.evaluateScript("clicks")?.toInt32() == beforeContinueClicks + 1)
        js.evaluateScript("continueButton.disabled=true")
        assert(js.evaluateScript(productAction)?.toDictionary()?["state"] as? String == "disabled")
        js.evaluateScript("button.disabled=false;document.querySelector=function(selector){if(selector.includes('add-to-cart'))return button;if(selector.includes('continueButton'))return continueButton;return null;}")
        assert(js.evaluateScript(productAction)?.toDictionary()?["kind"] as? String == "add")
        js.evaluateScript("location.pathname='/shop/product/other/a'")
        assert(js.evaluateScript(productAction)?.toDictionary()?["state"] as? String == "mismatch")
        assert(BrowserController.checkoutTransitionState("https://www.apple.com.cn/shop/bag") == "waiting")
        assert(BrowserController.checkoutTransitionState("https://www.apple.com.cn/shop/checkout") == "handoff")
        assert(BrowserController.checkoutTransitionState("https://www.apple.com.cn/shop/checkout/start") == "handoff")
        assert(BrowserController.checkoutTransitionState("https://secure.www.apple.com.cn/shop/checkout/start") == "handoff")
        assert(BrowserController.checkoutTransitionState("https://secure7.www.apple.com.cn/shop/checkout/start") == "handoff")
        assert(BrowserController.checkoutTransitionState("https://secure7.www.apple.com.cn.evil.example/shop/checkout") == "off_target")
        assert(BrowserController.checkoutTransitionState("http://www.apple.com.cn/shop/checkout") == "off_target")
        assert(BrowserController.checkoutTransitionState("https://secure7.www.apple.com.cn/shop/signIn") == "manual")
        assert(BrowserController.checkoutTransitionState("https://www.apple.com.cn/shop/signin") == "manual")
        assert(BrowserController.checkoutTransitionState("https://example.com/shop/checkout") == "off_target")

        js.evaluateScript("""
        location.pathname='/shop/bag';
        var quantity = {name:'quantity',id:'',value:'1',getAttribute:function(){return '';}};
        var item = {offsetWidth:1,offsetHeight:0,getClientRects:function(){return [];},innerText:'DEMO1/A',contains:function(){return false;},querySelectorAll:function(selector){return selector==='a[href]' ? [{href:'https://www.apple.com.cn/shop/product/demo1/a'}] : [quantity];}};
        document.querySelectorAll=function(){return [item];};
        """)
        let inspect = try BrowserController.bagInspectionExpression(expectedPartNumber: "DEMO1/A")
        assert(js.evaluateScript(inspect)?.toDictionary()?["state"] as? String == "confirmed")
        js.evaluateScript("quantity.value='2'")
        assert(js.evaluateScript(inspect)?.toDictionary()?["state"] as? String == "conflict")
        js.evaluateScript("quantity.value='1';document.querySelectorAll=function(){return [item,item];}")
        assert(js.evaluateScript(inspect)?.toDictionary()?["state"] as? String == "conflict")
        js.evaluateScript("document.querySelectorAll=function(){return [];};document.body={innerText:'你的购物袋是空的'}")
        assert(js.evaluateScript(inspect)?.toDictionary()?["state"] as? String == "empty")
        js.evaluateScript("document.body={innerText:'你的购物袋中没有商品。'}")
        assert(js.evaluateScript(inspect)?.toDictionary()?["state"] as? String == "empty")
        js.evaluateScript("document.body.innerText='正在加载'")
        assert(js.evaluateScript(inspect)?.toDictionary()?["state"] as? String == "unknown")
        print("Browser controller tests passed: profile ownership, before-release options, no-click states, exact product guard, bag identity and quantity")
    }
}
