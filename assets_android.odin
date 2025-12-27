#+build linux

package render

import "core:log"


import android "androidglue/ndkbindings"

when !DESKTOP_BUILD {

load_from_asset_pack_android :: proc() -> (asset: Asset, success: bool) {
	log.panic("Log from asset pack android not implemented")
}

}
