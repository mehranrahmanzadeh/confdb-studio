import 'package:flutter/material.dart';

/// Material equivalents of the design files' inline SVG icons (the `IC` maps).
abstract final class AppIcons {
  static const schemas = Icons.account_tree_outlined;
  static const schemasSelected = Icons.account_tree;
  static const data = Icons.storage_outlined;
  static const dataSelected = Icons.storage;
  static const access = Icons.power_outlined;
  static const accessSelected = Icons.power;
  static const views = Icons.visibility_outlined;

  static const ok = Icons.check_circle_outline;
  static const error = Icons.error_outline;
  static const warning = Icons.warning_amber_rounded;
  static const info = Icons.info_outline;
  static const help = Icons.help_outline;
  static const neutral = Icons.circle_outlined;
  static const lock = Icons.lock_outline;
  static const bolt = Icons.bolt;
  static const shield = Icons.shield_outlined;
  static const verified = Icons.verified_user_outlined;
  static const eye = Icons.visibility_outlined;
  static const eyeOff = Icons.visibility_off_outlined;
  static const add = Icons.add;
  static const remove = Icons.remove;
  static const edit = Icons.edit_outlined;
  static const link = Icons.link;
  static const unlink = Icons.link_off;
  static const undo = Icons.undo;
  static const readWrite = Icons.swap_horiz;
  static const user = Icons.person_outline;
  static const snap = Icons.inventory_2_outlined;
  static const terminal = Icons.terminal;
  static const copy = Icons.content_copy;
  static const check = Icons.check;
  static const close = Icons.close;
  static const expand = Icons.expand_more;
  static const collapse = Icons.expand_less;
  static const chevronRight = Icons.chevron_right;
  static const panelCollapseLeft = Icons.first_page;
  static const panelExpandRight = Icons.last_page;
  static const search = Icons.search;
  static const retry = Icons.refresh;
  static const play = Icons.play_arrow_outlined;
  static const delete = Icons.delete_outline;
  static const key = Icons.key_outlined;

  /// A map placeholder: any key (`{placeholder}`).
  static const placeholder = Icons.data_object;
  static const upload = Icons.upload_outlined;
  static const template = Icons.space_dashboard_outlined;
  static const back = Icons.arrow_back;
  static const next = Icons.arrow_forward;
  static const openDetails = Icons.open_in_new;
  static const hook = Icons.code;
  static const dash = Icons.remove;
  static const tune = Icons.tune;
  static const dragHandle = Icons.drag_indicator;

  // The Snap Store.
  static const store = Icons.cloud_outlined;
  static const storeSynced = Icons.cloud_done_outlined;
  static const storeOff = Icons.cloud_off_outlined;
  static const push = Icons.cloud_upload_outlined;
  static const pull = Icons.cloud_download_outlined;
  static const signIn = Icons.login;
  static const signOut = Icons.logout;
}
