import AppKit
import SwiftUI
import TabWMCore

/// Offscreen rendering only. Does not start window discovery, hotkeys, login items,
/// Dock inspection, or Accessibility mutations.
@MainActor
func runUISmoke(output: URL) {
    do {
        try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        let controller=AppController(dataDirectory:output.appendingPathComponent("data"))
        let first=WindowInfo(id:1,pid:0,appName:"Editor",bundleID:"example.editor",title:"Project — Editor",frame:CGRect(x:100,y:100,width:900,height:600))
        let second=WindowInfo(id:2,pid:0,appName:"Terminal",bundleID:"example.terminal",title:"Terminal — tabWM",frame:first.frame)
        let third=WindowInfo(id:3,pid:0,appName:"Browser",bundleID:"example.browser",title:"Documentation",frame:first.frame)
        controller.windows=[first,second,third]
        controller.engine.group(first,with:second);controller.engine.group(third,with:second)
        if let group=controller.groups.first {controller.engine.rename(group.id,name:"Development")}
        var retained:[NSWindow]=[]
        func render<V:View>(_ view:V,name:String,size:NSSize,dark:Bool?=nil)throws {
            let host=NSHostingView(rootView:view);host.frame=NSRect(origin:.zero,size:size)
            if let dark { host.appearance=NSAppearance(named:dark ? .darkAqua : .aqua) }
            let window=NSWindow(contentRect:NSRect(origin:CGPoint(x:10000,y:10000),size:size),styleMask:[.borderless],backing:.buffered,defer:false)
            window.contentView=host;retained.append(window)
            host.layoutSubtreeIfNeeded()
            guard let bitmap=host.bitmapImageRepForCachingDisplay(in:host.bounds) else{throw NSError(domain:"TabWM",code:1,userInfo:[NSLocalizedDescriptionKey:"Could not render \(name)"])}
            host.cacheDisplay(in:host.bounds,to:bitmap)
            guard let png=bitmap.representation(using:.png,properties:[:]) else{throw NSError(domain:"TabWM",code:2)}
            try png.write(to:output.appendingPathComponent(name+".png"))
        }
        try render(SettingsView(controller:controller),name:"settings",size:NSSize(width:900,height:720))
        for page in ["General","Grouping","Shortcuts","Appearance","How to Use","About"] {
            try render(SettingsView(controller:controller,category:page,pageOnly:true),name:"settings-"+page.lowercased().replacingOccurrences(of:" ",with:"-"),size:NSSize(width:760,height:page=="How to Use" ? 1700:1000))
        }
        try render(WindowPickerView(controller:controller,target:nil),name:"window-picker",size:NSSize(width:760,height:500))
        try render(SearchView(controller:controller),name:"search",size:NSSize(width:760,height:500))
        if let id=controller.groups.first?.id {
            try render(GroupFrameView(controller:controller,groupID:id),name:"tab-bar",size:NSSize(width:908,height:636))
            controller.settings.frameStyle="catppuccin";controller.settings.frameColor="mauve"
            try render(GroupFrameView(controller:controller,groupID:id),name:"tab-bar-catppuccin",size:NSSize(width:908,height:636))
            for color in ["mauve","rosewater","blue","dark"] {
                controller.settings.frameColor=color
                for dark in [false,true] {
                    try render(GroupFrameView(controller:controller,groupID:id).frame(height:80,alignment:.top),name:"strip-\(color)-\(dark ? "dark":"light")",size:NSSize(width:908,height:80),dark:dark)
                }
            }
            controller.settings.frameColor="mauve"
            try render(FrameStylePicker(controller:controller).padding(18).frame(width:340),name:"frame-style-picker",size:NSSize(width:340,height:260))
        }
        let result:[String:Any]=["status":"passed","rendered":["settings","window-picker","search","tab-bar"],"windows":controller.windows.count,"groups":controller.groups.count,"liveWindowActions":0]
        try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("result.json"))
        print("UI smoke passed: \(output.path)")
        NSApp.terminate(nil)
    } catch {fputs("UI smoke failed: \(error)\n",stderr);exit(1)}
}
