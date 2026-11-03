// "Who's playing?", for a game shared by several people. Apple's way to tell Apple TV profiles apart is the User Management capability, which a free Apple ID cannot have, so the app cannot see the active profile.
// With DM_TV_PLAYERS=<names, comma-separated> (TVPort's Players field) it asks instead, before the game starts, and each player gets a save folder of their own. With fewer than two names it goes straight to the game.
// A name keeps its folder for good, whatever else changes in the list: the first name listed takes the save that was already there, whoever picks first, and the others get save.p-<name>. The shader list is shared by all (pso_user.tsv beside them).
// A game whose only save is the console's (Animal Crossing: New Horizons, its island) keeps one folder, as on a Switch: each name is a user of its own instead, a resident of the same island (hle_account.c).
#import <UIKit/UIKit.h>
#import <GameController/GameController.h>
#include <stdlib.h>
#include <stdio.h>

static NSString *const FOLDERS = @"dmplayers", *const LAST = @"dmplayer.last", *const OWNER = @"dmplayer.owner";
int dm_console_save_only(void); void dm_host_preload_wait(void);

static NSArray<NSString *> *player_names(void) {
    const char *e = getenv("DM_TV_PLAYERS");
    NSMutableArray *names = [NSMutableArray array];
    for (NSString *part in [@(e ?: "") componentsSeparatedByString:@","]) {
        NSString *name = [part stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (name.length && ![names containsObject:name]) [names addObject:name];
    }
    return names;
}

static NSString *folder_for(NSString *name) {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    NSMutableDictionary *map = [[d dictionaryForKey:FOLDERS] mutableCopy] ?: [NSMutableDictionary dictionary];
    if (map[name]) return map[name];
    NSString *folder = @"save";
    if (![name isEqualToString:player_names().firstObject] || [map.allValues containsObject:folder]) {
        NSMutableString *slug = [NSMutableString string];
        for (NSUInteger i = 0; i < name.length; i++) { unichar c = [name.lowercaseString characterAtIndex:i]; if ((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9')) [slug appendFormat:@"%C", c]; }
        if (!slug.length) [slug setString:@"player"];
        folder = [@"save.p-" stringByAppendingString:slug];
        for (int n = 2; [map.allValues containsObject:folder]; n++) folder = [NSString stringWithFormat:@"save.p-%@-%d", slug, n];   // two names with the same letters
    }
    map[name] = folder;
    [d setObject:map forKey:FOLDERS]; [d synchronize];
    return folder;
}

// Everyone, for the host's user list. The first keeps the console's first user for good, so reordering the list does not swap anyone's resident
static NSString *users_of(NSArray<NSString *> *names) {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    NSString *owner = [d stringForKey:OWNER];
    if (!owner.length) { owner = names.firstObject; [d setObject:owner forKey:OWNER]; [d synchronize]; }
    NSMutableArray *users = [NSMutableArray arrayWithObject:owner];
    for (NSString *name in names) if (![name isEqualToString:owner]) [users addObject:name];
    return [users componentsJoinedByString:@","];
}

static void use_player(NSString *name) {
    dm_host_preload_wait();   // main's imports are known once loading is done
    NSString *where;
    if (dm_console_save_only()) {
        NSString *users = users_of(player_names());
        setenv("DM_USERS", users.UTF8String, 1);
        where = [@"the console's, users " stringByAppendingString:users];
    } else {
        NSString *caches = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
        where = folder_for(name);
        setenv("DM_SAVE", [caches stringByAppendingPathComponent:where].fileSystemRepresentation, 1);
    }
    setenv("DM_NICK", name.UTF8String, 1);   // the name a game shows for its player
    [NSUserDefaults.standardUserDefaults setObject:name forKey:LAST];
    fprintf(stderr, "[dm] front end: player %s, save %s\n", name.UTF8String, where.UTF8String);
}

@interface DmPlayerPicker : UIViewController
@property(copy, nonatomic) NSArray<NSString *> *names;
@property(copy, nonatomic) void (^chosen)(NSString *name);
@property(strong, nonatomic) NSMutableArray<UIButton *> *buttons;
@end
@implementation DmPlayerPicker
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.blackColor;
    UILabel *title = [UILabel new];
    title.text = @"Who's playing?"; title.font = [UIFont systemFontOfSize:57 weight:UIFontWeightSemibold]; title.textColor = UIColor.whiteColor;
    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[title]];
    stack.axis = UILayoutConstraintAxisVertical; stack.alignment = UIStackViewAlignmentCenter; stack.spacing = 32; stack.translatesAutoresizingMaskIntoConstraints = NO;
    [stack setCustomSpacing:64 afterView:title];
    self.buttons = [NSMutableArray array];
    for (NSString *name in self.names) {
        UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
        [b setTitle:name forState:UIControlStateNormal];
        b.titleLabel.font = [UIFont systemFontOfSize:38 weight:UIFontWeightMedium];
        [b addTarget:self action:@selector(pick:) forControlEvents:UIControlEventPrimaryActionTriggered];
        [b.widthAnchor constraintEqualToConstant:640].active = YES;
        [stack addArrangedSubview:b]; [self.buttons addObject:b];
    }
    [self.view addSubview:stack];
    [stack.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor].active = YES;
    [stack.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor].active = YES;
}
- (NSArray<id<UIFocusEnvironment>> *)preferredFocusEnvironments {   // whoever played last
    NSUInteger i = [self.names indexOfObject:[NSUserDefaults.standardUserDefaults stringForKey:LAST] ?: @""];
    return i == NSNotFound ? self.buttons : @[self.buttons[i]];
}
- (void)pick:(UIButton *)b { self.chosen(self.names[[self.buttons indexOfObject:b]]); }
@end

// front_ios.m: true = it calls done when the game may start
bool dm_show_launcher(void *view_controller, void (*done)(void)) {
    NSArray<NSString *> *names = player_names();
    if (names.count < 2) { if (names.count) use_player(names.firstObject); return false; }
    GCEventViewController *root = (__bridge GCEventViewController *)view_controller;
    root.controllerUserInteractionEnabled = YES;   // the controller walks this screen as the remote does; the game takes it back below
    DmPlayerPicker *picker = [DmPlayerPicker new];
    picker.names = names; picker.modalPresentationStyle = UIModalPresentationFullScreen;
    __weak DmPlayerPicker *weak = picker;
    picker.chosen = ^(NSString *name) {
        use_player(name);
        root.controllerUserInteractionEnabled = NO;
        [weak dismissViewControllerAnimated:NO completion:^{ done(); }];
    };
    [root presentViewController:picker animated:NO completion:nil];
    return true;
}
