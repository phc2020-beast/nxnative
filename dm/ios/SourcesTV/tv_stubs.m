// What the Apple TV app leaves out of dm/ios/Sources (project_tv.yml): tvOS has no settings screen before the game, so front_ios.m starts the game at once.
#include <stdbool.h>
bool dm_show_launcher(void *view_controller, void (*done)(void)) { (void)view_controller; (void)done; return false; }
