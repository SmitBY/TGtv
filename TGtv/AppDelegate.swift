import UIKit
import TDLibKit
import Combine
import Foundation

extension Foundation.Notification.Name {
    static let tgFileUpdated = Foundation.Notification.Name("tg.file.updated")
}

// Расширение для ручной обработки JSON от TDLib
extension TDLibKit.Update {
    static func fromRawJSON(_ data: Data) -> TDLibKit.Update? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["@type"] as? String else {
            return nil
        }
        
        // Обработка обновления позиции чата
        if type == "updateChatPosition",
           let chatId = json["chat_id"] as? Int64,
           let positionJson = json["position"] as? [String: Any],
           let positionType = positionJson["@type"] as? String,
           positionType == "chatPosition",
           let listJson = positionJson["list"] as? [String: Any],
           let listType = listJson["@type"] as? String,
           listType == "chatListMain",
           let orderString = positionJson["order"] as? String,
           let isPinned = positionJson["is_pinned"] as? Bool {
            
            let orderValue: Int64 = Int64(orderString) ?? 0
            let orderTd = TdInt64(orderValue)

            // Исправленный порядок аргументов и тип для order
            let position = TDLibKit.ChatPosition(
                isPinned: isPinned, // isPinned перед list
                list: .chatListMain, 
                order: orderTd, 
                source: .chatSourceMtprotoProxy 
            )
            
            return .updateChatPosition(.init(
                chatId: chatId,
                position: position
            ))
        }
        
        // Обработка обновления статуса пользователя
        if type == "updateUserStatus",
           let userId = json["user_id"] as? Int64, 
           let statusJson = json["status"] as? [String: Any],
           let statusType = statusJson["@type"] as? String {
            
            var userStatus: UserStatus
            switch statusType {
            case "userStatusOnline":
                if let expires = statusJson["expires"] as? Int {
                    userStatus = .userStatusOnline(.init(expires: expires))
                } else { return nil }
            case "userStatusOffline":
                if let wasOnline = statusJson["was_online"] as? Int {
                    // Добавляем byMyPrivacySettings, если он есть в TDLibKit.UserStatusOffline
                    userStatus = .userStatusOffline(.init(wasOnline: wasOnline))
                } else { return nil }
            case "userStatusRecently":
                userStatus = .userStatusRecently(.init(byMyPrivacySettings: false))
            case "userStatusLastWeek":
                userStatus = .userStatusLastWeek(.init(byMyPrivacySettings: false))
            case "userStatusLastMonth":
                userStatus = .userStatusLastMonth(.init(byMyPrivacySettings: false))
            case "userStatusEmpty":
                 userStatus = .userStatusEmpty // Без .init()
            default:
                return nil
            }
            return .updateUserStatus(.init(status: userStatus, userId: userId))
        }
        
        // Обработка обновления состояния авторизации
        if type == "updateAuthorizationState",
           let authState = json["authorization_state"] as? [String: Any],
           let authStateType = authState["@type"] as? String {
            
            var state: TDLibKit.AuthorizationState
            
            switch authStateType {
            case "authorizationStateWaitTdlibParameters":
                state = .authorizationStateWaitTdlibParameters
            case "authorizationStateWaitPhoneNumber":
                state = .authorizationStateWaitPhoneNumber
            case "authorizationStateWaitOtherDeviceConfirmation":
                if let link = authState["link"] as? String {
                    state = .authorizationStateWaitOtherDeviceConfirmation(.init(link: link))
                } else {
                    return nil
                }
            case "authorizationStateWaitPassword":
                let passwordHint = authState["password_hint"] as? String ?? ""
                let hasRecoveryEmailAddress = authState["has_recovery_email_address"] as? Bool ?? false
                let hasPassportData = authState["has_passport_data"] as? Bool ?? false
                let recoveryEmailAddressPattern = authState["recovery_email_address_pattern"] as? String ?? ""
                
                state = .authorizationStateWaitPassword(.init(
                    hasPassportData: hasPassportData,
                    hasRecoveryEmailAddress: hasRecoveryEmailAddress,
                    passwordHint: passwordHint,
                    recoveryEmailAddressPattern: recoveryEmailAddressPattern
                ))
            case "authorizationStateReady":
                state = .authorizationStateReady
            case "authorizationStateClosing":
                state = .authorizationStateClosing
            case "authorizationStateClosed":
                state = .authorizationStateClosed
            default:
                return nil
            }
            
            return .updateAuthorizationState(.init(authorizationState: state))
        }
        
        // Обработка обновления состояния подключения
        if type == "updateConnectionState",
           let connState = json["state"] as? [String: Any],
           let connStateType = connState["@type"] as? String {
            
            var state: TDLibKit.ConnectionState
            
            switch connStateType {
            case "connectionStateWaitingForNetwork":
                state = .connectionStateWaitingForNetwork
            case "connectionStateConnecting":
                state = .connectionStateConnecting
            case "connectionStateConnectingToProxy":
                state = .connectionStateConnectingToProxy
            case "connectionStateReady":
                state = .connectionStateReady
            case "connectionStateUpdating":
                state = .connectionStateUpdating
            default:
                return nil
            }
            
            return .updateConnectionState(.init(state: state))
        }
        
        // Обработка обновления типа реакции по умолчанию
        if type == "updateDefaultReactionType",
           let reactionType = json["reaction_type"] as? [String: Any],
           let reactionTypeType = reactionType["@type"] as? String {
            
            if reactionTypeType == "reactionTypeEmoji",
                let emoji = reactionType["emoji"] as? String {
                
                return .updateDefaultReactionType(.init(
                    reactionType: .reactionTypeEmoji(.init(emoji: emoji))
                ))
            }
            
            return nil
        }
        
        // Обработка параметров поиска анимаций
        if type == "updateAnimationSearchParameters",
           let provider = json["provider"] as? String,
           let emojisArray = json["emojis"] as? [String] {
            
            return .updateAnimationSearchParameters(.init(
                emojis: emojisArray,
                provider: provider
            ))
        }
        
        // Обработка обновления удаления сообщений
        if type == "updateDeleteMessages",
           let chatId = json["chat_id"] as? Int64,
           let messageIds = json["message_ids"] as? [Int64],
           let isPermanent = json["is_permanent"] as? Bool,
           let fromCache = json["from_cache"] as? Bool {
            
            let deleteMessages = TDLibKit.UpdateDeleteMessages(
                chatId: chatId,
                fromCache: fromCache,
                isPermanent: isPermanent,
                messageIds: messageIds
            )
            return .updateDeleteMessages(deleteMessages)
        }
        
        // Обработка updateUser
        if type == "updateUser",
           let userJson = json["user"] as? [String: Any],
           let userId = userJson["id"] as? Int64,
           let firstName = userJson["first_name"] as? String {
            
            // Опциональные поля с значениями по умолчанию
            let lastName = userJson["last_name"] as? String ?? ""
            let _ = userJson["username"] as? String // usernames обрабатывается сложнее, пока оставим так (заменяем на _)
            let phoneNumber = userJson["phone_number"] as? String ?? ""
            
            // Обработка status
            var status: UserStatus = .userStatusEmpty
            if let statusJson = userJson["status"] as? [String: Any],
               let statusType = statusJson["@type"] as? String {
                switch statusType {
                case "userStatusOnline":
                    if let expires = statusJson["expires"] as? Int {
                        status = .userStatusOnline(.init(expires: expires))
                    }
                case "userStatusOffline":
                    if let wasOnline = statusJson["was_online"] as? Int {
                        status = .userStatusOffline(.init(wasOnline: wasOnline))
                    }
                case "userStatusRecently":
                     status = .userStatusRecently(.init(byMyPrivacySettings: (statusJson["by_my_privacy_settings"] as? Bool ?? false)))
                case "userStatusLastWeek":
                     status = .userStatusLastWeek(.init(byMyPrivacySettings: (statusJson["by_my_privacy_settings"] as? Bool ?? false)))
                case "userStatusLastMonth":
                    status = .userStatusLastMonth(.init(byMyPrivacySettings: (statusJson["by_my_privacy_settings"] as? Bool ?? false)))
                default:
                    break // Оставляем .userStatusEmpty по умолчанию
                }
            }

            let accentColorId = userJson["accent_color_id"] as? Int // Опциональное поле
            let backgroundCustomEmojiId = userJson["background_custom_emoji_id"] as? String ?? "0"
            let profileAccentColorId = userJson["profile_accent_color_id"] as? Int
            let profileBackgroundCustomEmojiId = userJson["profile_background_custom_emoji_id"] as? String ?? "0"

            // Обработка UserType
            var userType: UserType = .userTypeRegular // Значение по умолчанию, без .init()
            if let typeJson = userJson["type"] as? [String: Any], let userTypeString = typeJson["@type"] as? String {
                switch userTypeString {
                case "userTypeRegular":
                    userType = .userTypeRegular
                case "userTypeDeleted":
                    userType = .userTypeDeleted
                case "userTypeBot":
                    // Извлекаем параметры в отдельные константы, чтобы помочь компилятору
                    let activeUserCount = typeJson["active_user_count"] as? Int ?? 0
                    let canBeAddedToAttachmentMenu = typeJson["can_be_added_to_attachment_menu"] as? Bool ?? false
                    let canBeEdited = typeJson["can_be_edited"] as? Bool ?? false
                    // let canBeInvitedToGroups = typeJson["can_be_invited_to_groups"] as? Bool ?? false // Закомментировано из-за ошибки компилятора
                    let canConnectToBusiness = typeJson["can_connect_to_business"] as? Bool ?? false
                    let canJoinGroups = typeJson["can_join_groups"] as? Bool ?? false
                    let canReadAllGroupMessages = typeJson["can_read_all_group_messages"] as? Bool ?? false
                    // let canSupportInlineQueries = typeJson["can_support_inline_queries"] as? Bool ?? false // Закомментировано из-за ошибки компилятора
                    let hasMainWebApp = typeJson["has_main_web_app"] as? Bool ?? false
                    let hasTopics = typeJson["has_topics"] as? Bool ?? false
                    let inlineQueryPlaceholder = typeJson["inline_query_placeholder"] as? String ?? ""
                    let isInline = typeJson["is_inline"] as? Bool ?? false
                    let needLocation = typeJson["need_location"] as? Bool ?? false
                    
                    userType = .userTypeBot(.init(
                        activeUserCount: activeUserCount,
                        canBeAddedToAttachmentMenu: canBeAddedToAttachmentMenu,
                        canBeEdited: canBeEdited,
                        canConnectToBusiness: canConnectToBusiness,
                        canJoinGroups: canJoinGroups,
                        canReadAllGroupMessages: canReadAllGroupMessages,
                        hasMainWebApp: hasMainWebApp,
                        hasTopics: hasTopics,
                        inlineQueryPlaceholder: inlineQueryPlaceholder,
                        isInline: isInline,
                        needLocation: needLocation
                    ))
                case "userTypeUnknown":
                    userType = .userTypeUnknown
                default:
                    break
                }
            }
            
            // Прочие поля User, которые нужно парсить
            let isContact = userJson["is_contact"] as? Bool ?? false
            let isMutualContact = userJson["is_mutual_contact"] as? Bool ?? false
            // ... добавьте остальные поля по необходимости, делая их опциональными или с default значениями

            let user = TDLibKit.User(
                accentColorId: accentColorId ?? 0,
                activeStoryState: nil, // TODO: Parse activeStoryState
                addedToAttachmentMenu: userJson["added_to_attachment_menu"] as? Bool ?? false,
                backgroundCustomEmojiId: TdInt64(Int64(backgroundCustomEmojiId) ?? 0),
                emojiStatus: nil,
                firstName: firstName,
                haveAccess: userJson["have_access"] as? Bool ?? true,
                id: userId,
                isCloseFriend: userJson["is_close_friend"] as? Bool ?? false,
                isContact: isContact,
                isMutualContact: isMutualContact,
                isPremium: userJson["is_premium"] as? Bool ?? false,
                isSupport: userJson["is_support"] as? Bool ?? false,
                languageCode: userJson["language_code"] as? String ?? "",
                lastName: lastName,
                paidMessageStarCount: Int64(userJson["paid_message_star_count"] as? Int ?? 0),
                phoneNumber: phoneNumber,
                profileAccentColorId: profileAccentColorId ?? -1,
                profileBackgroundCustomEmojiId: TdInt64(Int64(profileBackgroundCustomEmojiId) ?? 0),
                profilePhoto: nil,
                restrictionInfo: nil, // TODO: Parse restrictionInfo
                restrictsNewChats: userJson["restricts_new_chats"] as? Bool ?? false,
                status: status,
                type: userType,
                upgradedGiftColors: nil, // TODO: Parse upgradedGiftColors
                usernames: nil,
                verificationStatus: nil
            )
            return .updateUser(.init(user: user))
        }
        
        // Обработка обновления супергруппы (полный ручной парсинг)
        if type == "updateSupergroup",
           let supergroupJson = json["supergroup"] as? [String: Any] {
            if let supergroup = parseSupergroup(fromJson: supergroupJson) {
                return .updateSupergroup(.init(supergroup: supergroup))
            } else {
                return nil // Позволяем Codable попробовать снова или возвращаем ошибку
            }
        }

        // Обработка обновления нового чата (полный ручной парсинг)
        if type == "updateNewChat",
           let chatJson = json["chat"] as? [String: Any] {
            if let chat = parseChat(fromJson: chatJson) {
                return .updateNewChat(.init(chat: chat))
            } else {
                return nil // Позволяем Codable попробовать снова или возвращаем ошибку
            }
        }
        
        return nil
    }

    // --- Вспомогательные функции парсинга ---

    // Парсер для Supergroup
    private static func parseSupergroup(fromJson json: [String: Any]) -> TDLibKit.Supergroup? {
        guard let id = json["id"] as? Int64,
              let date = json["date"] as? Int,
              let statusJson = json["status"] as? [String: Any],
              let status = parseChatMemberStatus(fromJson: statusJson)
        else { return nil }

        let usernames = parseUsernames(fromJson: json["usernames"] as? [String: Any]) // Optional
        let memberCount = json["member_count"] as? Int ?? 0
        let boostLevel = json["boost_level"] as? Int ?? 0 // Опционально, значение по умолчанию 0
        let hasLinkedChat = json["has_linked_chat"] as? Bool ?? false
        let hasLocation = json["has_location"] as? Bool ?? false
        let signMessages = json["sign_messages"] as? Bool ?? true
        let showMessageSender = json["show_message_sender"] as? Bool ?? true
        let joinToSendMessages = json["join_to_send_messages"] as? Bool ?? false
        let joinByRequest = json["join_by_request"] as? Bool ?? false
        let isSlowModeEnabled = json["is_slow_mode_enabled"] as? Bool ?? false
        let isChannel = json["is_channel"] as? Bool ?? false
        let isBroadcastGroup = json["is_broadcast_group"] as? Bool ?? false
        let isForum = json["is_forum"] as? Bool ?? false
        let verificationStatus = parseVerificationStatus(fromJson: json["verification_status"] as? [String: Any]) // Используем парсер (пока nil)
        let _ = json["has_sensitive_content"] as? Bool ?? false
        let _ = json["restriction_reason"] as? String ?? ""
        let paidMessageStarCount = Int64(json["paid_message_star_count"] as? Int ?? 0)
        let _ = json["has_active_stories"] as? Bool ?? false
        let _ = json["has_unread_active_stories"] as? Bool ?? false

        return TDLibKit.Supergroup(
            activeStoryState: nil, // TODO: Parse activeStoryState
            boostLevel: boostLevel,
            date: date,
            hasAutomaticTranslation: json["has_automatic_translation"] as? Bool ?? false,
            hasDirectMessagesGroup: json["has_direct_messages_group"] as? Bool ?? false,
            hasForumTabs: json["has_forum_tabs"] as? Bool ?? false,
            hasLinkedChat: hasLinkedChat,
            hasLocation: hasLocation,
            id: id,
            isAdministeredDirectMessagesGroup: json["is_administered_direct_messages_group"] as? Bool ?? false,
            isBroadcastGroup: isBroadcastGroup,
            isChannel: isChannel,
            isDirectMessagesGroup: json["is_direct_messages_group"] as? Bool ?? false,
            isForum: isForum,
            isSlowModeEnabled: isSlowModeEnabled,
            joinByRequest: joinByRequest,
            joinToSendMessages: joinToSendMessages,
            memberCount: memberCount,
            paidMessageStarCount: paidMessageStarCount,
            restrictionInfo: nil, // TODO: Parse restrictionInfo
            showMessageSender: showMessageSender,
            signMessages: signMessages,
            status: status,
            usernames: usernames,
            verificationStatus: verificationStatus
        )
    }

    // Парсер для Chat
    private static func parseChat(fromJson json: [String: Any]) -> TDLibKit.Chat? {
         guard let id = json["id"] as? Int64,
               let typeJson = json["type"] as? [String: Any],
               let type = parseChatType(fromJson: typeJson),
               let title = json["title"] as? String,
               let permissionsJson = json["permissions"] as? [String: Any],
               let permissions = parseChatPermissions(fromJson: permissionsJson),
               let notificationSettingsJson = json["notification_settings"] as? [String: Any],
               let notificationSettings = parseChatNotificationSettings(fromJson: notificationSettingsJson),
               let availableReactionsJson = json["available_reactions"] as? [String: Any],
               let availableReactions = parseChatAvailableReactions(fromJson: availableReactionsJson)
         else { return nil }

        let photo = parseChatPhotoInfo(fromJson: json["photo"] as? [String: Any]) // Optional
        let accentColorId = json["accent_color_id"] as? Int ?? 0 // Опционально, default 0
        let backgroundCustomEmojiIdStr = json["background_custom_emoji_id"] as? String ?? "0"
        let backgroundCustomEmojiId = TdInt64(Int64(backgroundCustomEmojiIdStr) ?? 0)
        let profileAccentColorId = json["profile_accent_color_id"] as? Int ?? -1 // Optional, default -1
        let profileBackgroundCustomEmojiIdStr = json["profile_background_custom_emoji_id"] as? String ?? "0"
        let profileBackgroundCustomEmojiId = TdInt64(Int64(profileBackgroundCustomEmojiIdStr) ?? 0)
        let lastMessage = parseMessage(fromJson: json["last_message"] as? [String: Any]) // Optional
        let positions = (json["positions"] as? [[String: Any]] ?? []).compactMap(parseChatPosition) // Optional array
        // chat_lists - обычно пустой в updateNewChat, можно пропустить или парсить при необходимости
        // message_sender_id - TODO: parse MessageSender
        // block_list - TODO: parse BlockList
        let hasProtectedContent = json["has_protected_content"] as? Bool ?? false
        let isTranslatable = json["is_translatable"] as? Bool ?? false
        let isMarkedAsUnread = json["is_marked_as_unread"] as? Bool ?? false
        let viewAsTopics = json["view_as_topics"] as? Bool ?? false
        let hasScheduledMessages = json["has_scheduled_messages"] as? Bool ?? false
        let canBeDeletedOnlyForSelf = json["can_be_deleted_only_for_self"] as? Bool ?? false
        let canBeDeletedForAllUsers = json["can_be_deleted_for_all_users"] as? Bool ?? false
        let canBeReported = json["can_be_reported"] as? Bool ?? true
        let defaultDisableNotification = json["default_disable_notification"] as? Bool ?? false
        let unreadCount = json["unread_count"] as? Int ?? 0
        let lastReadInboxMessageId = json["last_read_inbox_message_id"] as? Int64 ?? 0
        let lastReadOutboxMessageId = json["last_read_outbox_message_id"] as? Int64 ?? 0
        let unreadMentionCount = json["unread_mention_count"] as? Int ?? 0
        let unreadReactionCount = json["unread_reaction_count"] as? Int ?? 0
        let messageAutoDeleteTime = json["message_auto_delete_time"] as? Int ?? 0
        // emoji_status - TODO: parse EmojiStatus
        // background - TODO: parse ChatBackground
        let _ = json["theme_name"] as? String ?? ""
        // action_bar - TODO: parse ChatActionBar
        // business_bot_manage_bar - TODO: parse BusinessBotManageBar
        let videoChat = parseVideoChat(fromJson: json["video_chat"] as? [String: Any]) // Optional
        // pending_join_requests - TODO: parse ChatJoinRequestsInfo
        let replyMarkupMessageId = json["reply_markup_message_id"] as? Int64 ?? 0
        // draft_message - TODO: parse DraftMessage
        let clientData = json["client_data"] as? String ?? ""

         return TDLibKit.Chat(
            accentColorId: accentColorId,
            actionBar: nil, // TODO
            availableReactions: availableReactions,
            background: nil, // TODO
            backgroundCustomEmojiId: backgroundCustomEmojiId,
            blockList: nil, // Исправляем метку с block_list на blockList
            businessBotManageBar: nil, // TODO
            canBeDeletedForAllUsers: canBeDeletedForAllUsers,
            canBeDeletedOnlyForSelf: canBeDeletedOnlyForSelf,
            canBeReported: canBeReported,
            chatLists: [], // Обычно пустое
            clientData: clientData,
            defaultDisableNotification: defaultDisableNotification,
            draftMessage: nil, // TODO
            emojiStatus: nil, // TODO
            hasProtectedContent: hasProtectedContent,
            hasScheduledMessages: hasScheduledMessages,
            id: id,
            isMarkedAsUnread: isMarkedAsUnread,
            isTranslatable: isTranslatable,
            lastMessage: lastMessage,
            lastReadInboxMessageId: lastReadInboxMessageId,
            lastReadOutboxMessageId: lastReadOutboxMessageId,
            messageAutoDeleteTime: messageAutoDeleteTime,
            messageSenderId: nil, // TODO
            notificationSettings: notificationSettings,
            pendingJoinRequests: nil, // TODO
            permissions: permissions,
            photo: photo,
            positions: positions,
            profileAccentColorId: profileAccentColorId,
            profileBackgroundCustomEmojiId: profileBackgroundCustomEmojiId,
            replyMarkupMessageId: replyMarkupMessageId,
            theme: nil, // TODO: Parse ChatTheme
            title: title,
            type: type,
            unreadCount: unreadCount,
            unreadMentionCount: unreadMentionCount,
            unreadReactionCount: unreadReactionCount,
            upgradedGiftColors: nil, // TODO: Parse UpgradedGiftColors
            videoChat: videoChat ?? VideoChat(defaultParticipantId: nil, groupCallId: 0, hasParticipants: false), // Предоставляем default, если nil
            viewAsTopics: viewAsTopics
        )
    }

    // --- Вспомогательные парсеры для вложенных структур ---
    // (Нужно реализовать или доработать существующие парсеры для всех TODO выше)

    private static func parseChatMemberStatus(fromJson json: [String: Any]) -> ChatMemberStatus? {
        guard let type = json["@type"] as? String else { return nil }
        switch type {
        case "chatMemberStatusMember":
             return .chatMemberStatusMember(.init(memberUntilDate: json["member_until_date"] as? Int ?? 0))
        case "chatMemberStatusLeft":
             return .chatMemberStatusLeft
        case "chatMemberStatusCreator":
            let customTitle = json["custom_title"] as? String ?? ""
            let isAnonymous = json["is_anonymous"] as? Bool ?? false
            let isMember = json["is_member"] as? Bool ?? true
            return .chatMemberStatusCreator(.init(
                customTitle: customTitle,
                isAnonymous: isAnonymous,
                isMember: isMember
            ))
        case "chatMemberStatusAdministrator":
            let canBeEdited = json["can_be_edited"] as? Bool ?? false
            let customTitle = json["custom_title"] as? String ?? ""
            let rightsJson = json["rights"] as? [String: Any]
            let rights = ChatAdministratorRights(
                canChangeInfo: rightsJson?["can_change_info"] as? Bool ?? false,
                canDeleteMessages: rightsJson?["can_delete_messages"] as? Bool ?? false,
                canDeleteStories: rightsJson?["can_delete_stories"] as? Bool ?? false,
                canEditMessages: rightsJson?["can_edit_messages"] as? Bool ?? false,
                canEditStories: rightsJson?["can_edit_stories"] as? Bool ?? false,
                canInviteUsers: rightsJson?["can_invite_users"] as? Bool ?? false,
                canManageChat: rightsJson?["can_manage_chat"] as? Bool ?? false,
                canManageDirectMessages: rightsJson?["can_manage_direct_messages"] as? Bool ?? false,
                canManageTopics: rightsJson?["can_manage_topics"] as? Bool ?? false,
                canManageVideoChats: rightsJson?["can_manage_video_chats"] as? Bool ?? false,
                canPinMessages: rightsJson?["can_pin_messages"] as? Bool ?? false,
                canPostMessages: rightsJson?["can_post_messages"] as? Bool ?? false,
                canPostStories: rightsJson?["can_post_stories"] as? Bool ?? false,
                canPromoteMembers: rightsJson?["can_promote_members"] as? Bool ?? false,
                canRestrictMembers: rightsJson?["can_restrict_members"] as? Bool ?? false,
                isAnonymous: rightsJson?["is_anonymous"] as? Bool ?? false
            )
            return .chatMemberStatusAdministrator(.init(
                canBeEdited: canBeEdited,
                customTitle: customTitle,
                rights: rights
            ))
        case "chatMemberStatusRestricted":
            let isMember = json["is_member"] as? Bool ?? false
            let restrictedUntilDate = json["restricted_until_date"] as? Int ?? 0
            let permissionsJson = json["permissions"] as? [String: Any]
            let permissions = permissionsJson.flatMap { parseChatPermissions(fromJson: $0) } ?? ChatPermissions(
                canAddLinkPreviews: false,
                canChangeInfo: false,
                canCreateTopics: false,
                canInviteUsers: false,
                canPinMessages: false,
                canSendAudios: false,
                canSendBasicMessages: false,
                canSendDocuments: false,
                canSendOtherMessages: false,
                canSendPhotos: false,
                canSendPolls: false,
                canSendVideoNotes: false,
                canSendVideos: false,
                canSendVoiceNotes: false
            )
            return .chatMemberStatusRestricted(.init(
                isMember: isMember,
                permissions: permissions,
                restrictedUntilDate: restrictedUntilDate
            ))
        case "chatMemberStatusBanned":
            let bannedUntilDate = json["banned_until_date"] as? Int ?? 0
            return .chatMemberStatusBanned(.init(bannedUntilDate: bannedUntilDate))
        default:
            return nil
        }
    }

    private static func parseUsernames(fromJson json: [String: Any]?) -> Usernames? {
        guard let json = json,
              let activeUsernames = json["active_usernames"] as? [String],
              let disabledUsernames = json["disabled_usernames"] as? [String],
              let editableUsername = json["editable_username"] as? String
        else { return nil } // Usernames может быть nil
        return .init(activeUsernames: activeUsernames, collectibleUsernames: json["collectible_usernames"] as? [String] ?? [], disabledUsernames: disabledUsernames, editableUsername: editableUsername)
    }

    private static func parseChatType(fromJson json: [String: Any]) -> ChatType? {
         guard let type = json["@type"] as? String else { return nil }
         switch type {
         case "chatTypePrivate":
             guard let userId = json["user_id"] as? Int64 else { return nil }
             return .chatTypePrivate(.init(userId: userId))
         case "chatTypeBasicGroup":
             guard let basicGroupId = json["basic_group_id"] as? Int64 else { return nil }
             return .chatTypeBasicGroup(.init(basicGroupId: basicGroupId))
         case "chatTypeSupergroup":
             guard let supergroupId = json["supergroup_id"] as? Int64,
                   let isChannel = json["is_channel"] as? Bool else { return nil }
             return .chatTypeSupergroup(.init(isChannel: isChannel, supergroupId: supergroupId))
         case "chatTypeSecret":
              guard let secretChatId = json["secret_chat_id"] as? Int, // Int, не Int64
                    let userId = json["user_id"] as? Int64 else { return nil }
              return .chatTypeSecret(.init(secretChatId: secretChatId, userId: userId))
         default:
             print("parseChatType: Неизвестный тип \(type)")
             return nil
         }
    }

    private static func parseChatPermissions(fromJson json: [String: Any]) -> ChatPermissions? {
        // Извлекаем параметры в константы
        let canAddLinkPreviews = json["can_add_link_previews"] as? Bool ?? false
        let canChangeInfo = json["can_change_info"] as? Bool ?? false
        let canCreateTopics = json["can_create_topics"] as? Bool ?? false
        let canInviteUsers = json["can_invite_users"] as? Bool ?? false
        let canPinMessages = json["can_pin_messages"] as? Bool ?? false
        let canSendAudios = json["can_send_audios"] as? Bool ?? false
        let canSendBasicMessages = json["can_send_basic_messages"] as? Bool ?? false
        let canSendDocuments = json["can_send_documents"] as? Bool ?? false
        let canSendOtherMessages = json["can_send_other_messages"] as? Bool ?? false
        let canSendPhotos = json["can_send_photos"] as? Bool ?? false
        let canSendPolls = json["can_send_polls"] as? Bool ?? false
        let canSendVideoNotes = json["can_send_video_notes"] as? Bool ?? false
        let canSendVideos = json["can_send_videos"] as? Bool ?? false
        let canSendVoiceNotes = json["can_send_voice_notes"] as? Bool ?? false
        
        return .init(
            canAddLinkPreviews: canAddLinkPreviews,
            canChangeInfo: canChangeInfo,
            canCreateTopics: canCreateTopics,
            canInviteUsers: canInviteUsers,
            canPinMessages: canPinMessages,
            canSendAudios: canSendAudios,
            canSendBasicMessages: canSendBasicMessages,
            canSendDocuments: canSendDocuments,
            canSendOtherMessages: canSendOtherMessages,
            canSendPhotos: canSendPhotos,
            canSendPolls: canSendPolls,
            canSendVideoNotes: canSendVideoNotes,
            canSendVideos: canSendVideos,
            canSendVoiceNotes: canSendVoiceNotes
        )
    }
    
    private static func parseFile(fromJson json: [String: Any]?) -> File? {
         guard let json = json,
               let id = json["id"] as? Int,
               let size = json["size"] as? Int64, // Был Int, должен быть Int64? Проверить TDLibKit
               let localJson = json["local"] as? [String: Any],
               let local = parseLocalFile(fromJson: localJson),
               let remoteJson = json["remote"] as? [String: Any],
               let remote = parseRemoteFile(fromJson: remoteJson)
         else { return nil }
         
         let expectedSize = json["expected_size"] as? Int64 ?? size // Может отсутствовать
         
         return File(expectedSize: expectedSize, id: id, local: local, remote: remote, size: size)
    }

    private static func parseLocalFile(fromJson json: [String: Any]?) -> LocalFile? {
        guard let json = json else { return nil }
        return LocalFile(
            canBeDeleted: json["can_be_deleted"] as? Bool ?? false,
            canBeDownloaded: json["can_be_downloaded"] as? Bool ?? true,
            downloadOffset: json["download_offset"] as? Int64 ?? 0, // Int? Int64?
            downloadedPrefixSize: json["downloaded_prefix_size"] as? Int64 ?? 0, // Int? Int64?
            downloadedSize: json["downloaded_size"] as? Int64 ?? 0, // Int? Int64?
            isDownloadingActive: json["is_downloading_active"] as? Bool ?? false,
            isDownloadingCompleted: json["is_downloading_completed"] as? Bool ?? false,
            path: json["path"] as? String ?? ""
        )
    }

    private static func parseRemoteFile(fromJson json: [String: Any]?) -> RemoteFile? {
        guard let json = json,
              let id = json["id"] as? String
              // unique_id может отсутствовать в некоторых случаях
        else { return nil }
        return RemoteFile(
            id: id,
            isUploadingActive: json["is_uploading_active"] as? Bool ?? false,
            isUploadingCompleted: json["is_uploading_completed"] as? Bool ?? true,
            uniqueId: json["unique_id"] as? String ?? "",
            uploadedSize: json["uploaded_size"] as? Int64 ?? 0 // Int? Int64?
        )
    }
    
     private static func parseMinithumbnail(fromJson json: [String: Any]?) -> Minithumbnail? {
        guard let json = json,
              let width = json["width"] as? Int,
              let height = json["height"] as? Int,
              let dataString = json["data"] as? String,
              let data = Data(base64Encoded: dataString) // Данные обычно base64
        else { return nil }
        return Minithumbnail(data: data, height: height, width: width)
    }
    
    private static func parseChatPhotoInfo(fromJson json: [String: Any]?) -> ChatPhotoInfo? {
        guard let json = json,
              let smallJson = json["small"] as? [String: Any],
              let small = parseFile(fromJson: smallJson),
              let bigJson = json["big"] as? [String: Any],
              let big = parseFile(fromJson: bigJson)
        else { return nil }
        
        let minithumbnail = parseMinithumbnail(fromJson: json["minithumbnail"] as? [String: Any])
        let hasAnimation = json["has_animation"] as? Bool ?? false
        let isPersonal = json["is_personal"] as? Bool ?? false
        
        return ChatPhotoInfo(big: big, hasAnimation: hasAnimation, isPersonal: isPersonal, minithumbnail: minithumbnail, small: small)
    }
    
    private static func parseMessage(fromJson json: [String: Any]?) -> Message? {
         guard let json = json,
               let id = json["id"] as? Int64,
               let chatId = json["chat_id"] as? Int64,
               let date = json["date"] as? Int,
               let contentJson = json["content"] as? [String: Any],
               let content = parseMessageContent(fromJson: contentJson), // TODO: Реализовать parseMessageContent
               let senderIdJson = json["sender_id"] as? [String: Any], // Убираем senderId из guard, обработаем ниже
               // Убедимся, что все обязательные поля тут
               let isOutgoing = json["is_outgoing"] as? Bool, // Добавляем обязательные поля в guard
               let _ = json["chat_id"] as? Int64,
               let _ = json["id"] as? Int64
               // Добавить остальные обязательные поля Message
         else { return nil }

         // Извлекаем остальные поля Message в константы
         let authorSignature = json["author_signature"] as? String ?? ""
         let _ = json["can_be_deleted_for_all_users"] as? Bool ?? false
         let _ = json["can_be_deleted_only_for_self"] as? Bool ?? false
         let _ = false // TODO: canBeEdited
         let _ = false // TODO: canBeForwarded
         let _ = false // TODO: canBeRepliedInAnotherChat
         let canBeSaved = json["can_be_saved"] as? Bool ?? true
         let _ = false // TODO: canGetAddedReactions
         let _ = false // TODO: canGetMediaTimestampLinks
         let _ = false // TODO: canGetMessageThread
         let _ = false // TODO: canGetReadDate
         let _ = false // TODO: canGetStatistics
         let _ = false // TODO: canGetViewers
         let _ = false // TODO: canReportReactions
         let containsUnreadMention = json["contains_unread_mention"] as? Bool ?? false
         let editDate = json["edit_date"] as? Int ?? 0
         let effectIdString = json["effect_id"] as? String ?? "0"
         let effectIdInt64 = Int64(effectIdString) ?? 0 // Сначала в Int64
         let effectId = TdInt64(effectIdInt64) // Потом в TdInt64
         let forwardInfo: MessageForwardInfo? = nil // TODO
         let _ = json["has_sensitive_content"] as? Bool ?? false // Deprecated in TDLib 1.8.58+
         let hasTimestampedMedia = json["has_timestamped_media"] as? Bool ?? false
         let importInfo: MessageImportInfo? = nil // TODO
         let interactionInfo: MessageInteractionInfo? = nil // TODO: parseMessageInteractionInfo
         let isChannelPost = json["is_channel_post"] as? Bool ?? false
         let isFromOffline = json["is_from_offline"] as? Bool ?? false
         let isPinned = json["is_pinned"] as? Bool ?? false
        let _ = json["is_topic_message"] as? Bool ?? false
        let mediaAlbumId = TdInt64(Int64(json["media_album_id"] as? String ?? "0") ?? 0)
        let _ = json["message_thread_id"] as? Int64 ?? 0
        let paidMessageStarCount = Int64(json["paid_message_star_count"] as? Int ?? 0)
        let _ : Int64 = 0 // TODO: replyInChatId
        let replyMarkup: ReplyMarkup? = nil // TODO: parseReplyMarkup
        let replyTo: MessageReplyTo? = nil // TODO: parseMessageReplyTo
        let _ = json["restriction_reason"] as? String ?? ""
        let _ = json["saved_messages_topic_id"] as? Int64 ?? 0
         let schedulingState: MessageSchedulingState? = nil // TODO: parseMessageSchedulingState
         let autoDeleteIn = json["auto_delete_in"] as? Double ?? 0.0
         let selfDestructIn = json["self_destruct_in"] as? Double ?? 0.0 // Возвращаем selfDestructIn
         let selfDestructType: MessageSelfDestructType? = nil // TODO: parseMessageSelfDestructType
         let senderBoostCount = json["sender_boost_count"] as? Int ?? 0
         let senderBusinessBotUserId = json["sender_business_bot_user_id"] as? Int64 ?? 0
         let senderId = parseMessageSender(fromJson: senderIdJson) // Парсим senderId отдельно
         let sendingState: MessageSendingState? = nil // TODO: parseMessageSendingState
         let unreadReactions: [UnreadReaction] = [] // TODO: parseMessageReaction
         let viaBotUserId = json["via_bot_user_id"] as? Int64 ?? 0

         // Проверяем, что senderId удалось распарсить, т.к. он обязателен
         guard let senderId = senderId else { 
            print("parseMessage: Не удалось распарсить обязательный senderId")
            return nil
         }

        return Message(
            authorSignature: authorSignature,
            autoDeleteIn: autoDeleteIn,
            canBeSaved: canBeSaved,
            chatId: chatId,
            containsUnreadMention: containsUnreadMention,
            content: content,
            date: date,
            editDate: editDate,
            effectId: effectId,
            factCheck: nil,
            forwardInfo: forwardInfo,
            hasTimestampedMedia: hasTimestampedMedia,
            id: id,
            importInfo: importInfo,
            interactionInfo: interactionInfo,
            isChannelPost: isChannelPost,
            isFromOffline: isFromOffline,
            isOutgoing: isOutgoing,
            isPaidStarSuggestedPost: false, // Default
            isPaidTonSuggestedPost: false, // Default
            isPinned: isPinned,
            mediaAlbumId: mediaAlbumId,
            paidMessageStarCount: paidMessageStarCount,
            replyMarkup: replyMarkup,
            replyTo: replyTo,
            restrictionInfo: nil, // TODO: Parse restrictionInfo
            schedulingState: schedulingState,
            selfDestructIn: selfDestructIn,
            selfDestructType: selfDestructType,
            senderBoostCount: senderBoostCount,
            senderBusinessBotUserId: senderBusinessBotUserId,
            senderId: senderId,
            sendingState: sendingState,
            suggestedPostInfo: nil, // TODO: Parse suggestedPostInfo
            topicId: nil, // TODO: Parse topicId
            unreadReactions: unreadReactions,
            viaBotUserId: viaBotUserId
        )
    }

    // TODO: Реализовать парсеры для:
    // - parseMessageContent (messageText, messagePhoto, messageVideo, etc.)
    // - parseMessageSender (messageSenderUser, messageSenderChat) - ВАЖНО, так как senderId обязателен!
    // - parseMessageInteractionInfo
    // - parseMessageReplyTo
    // - parseReplyMarkup
    // - parseMessageSchedulingState
    // - parseMessageSendingState
    // - parseMessageSelfDestructType
    // - parseEmojiStatus
    // - parseChatBackground
    // - parseChatActionBar
    // - parseBusinessBotManageBar
    // - parseChatJoinRequestsInfo
    // - parseDraftMessage
    // - parseVerificationStatus
    // - parseBlockList
    // - parseReactionType
    
    private static func parseMessageContent(fromJson json: [String: Any]?) -> MessageContent? {
         guard let json = json, let type = json["@type"] as? String else { return nil }
         switch type {
             case "messageText":
                 let textJson = json["text"] as? [String: Any]
                 let text = parseFormattedText(fromJson: textJson)
                 // TODO: parse web_page / link_preview
                 return .messageText(.init(linkPreview: nil, linkPreviewOptions: nil, text: text ?? FormattedText(entities: [], text: ""))) // Убираем webPage, добавляем linkPreview
             // Добавьте другие типы контента (Photo, Video, Audio, Document, Sticker, etc.)
             default:
                 print("parseMessageContent: Неизвестный тип \(type)")
                 return nil // Или вернуть .messageUnsupported?
         }
    }
    
    private static func parseFormattedText(fromJson json: [String: Any]?) -> FormattedText? {
         guard let json = json, let text = json["text"] as? String else { return nil }
         let entities = (json["entities"] as? [[String: Any]] ?? []).compactMap(parseTextEntity)
         return FormattedText(entities: entities, text: text)
    }

    // TODO: Реализовать parseTextEntity
    private static func parseTextEntity(fromJson json: [String: Any]?) -> TextEntity? {
        // Placeholder
        return nil
    }

    private static func parseChatPosition(fromJson json: [String: Any]?) -> ChatPosition? {
        guard let json = json,
              let listJson = json["list"] as? [String: Any],
              let list = parseChatList(fromJson: listJson), // TODO: parseChatList
              let orderStr = json["order"] as? String,
              let order = Int64(orderStr),
              let isPinned = json["is_pinned"] as? Bool
              // source может отсутствовать
        else { return nil }
        // TODO: parse ChatSource?
        return ChatPosition(isPinned: isPinned, list: list, order: TdInt64(order), source: nil)
    }

    // TODO: Реализовать parseChatList
    private static func parseChatList(fromJson json: [String: Any]?) -> ChatList? {
        // Placeholder
        // Пример для chatListMain:
        // guard let json = json, json["@type"] as? String == "chatListMain" else { return nil }
        // return .chatListMain
        return nil
    }

    private static func parseChatNotificationSettings(fromJson json: [String: Any]?) -> ChatNotificationSettings? {
        guard let json = json else { return nil }
        // Извлекаем параметры в константы
        let disableMentionNotifications = json["disable_mention_notifications"] as? Bool ?? false
        let disablePinnedMessageNotifications = json["disable_pinned_message_notifications"] as? Bool ?? false
        let muteFor = json["mute_for"] as? Int ?? 0
        let muteStories = json["mute_stories"] as? Bool ?? false
        let showPreview = json["show_preview"] as? Bool ?? false
        let showStoryPoster = json["show_story_poster"] as? Bool ?? true
        let soundId = TdInt64(Int64(json["sound_id"] as? String ?? "-1") ?? -1)
        let storySoundId = TdInt64(Int64(json["story_sound_id"] as? String ?? "-1") ?? -1)
        let useDefaultDisableMentionNotifications = json["use_default_disable_mention_notifications"] as? Bool ?? true
        let useDefaultDisablePinnedMessageNotifications = json["use_default_disable_pinned_message_notifications"] as? Bool ?? true
        let useDefaultMuteFor = json["use_default_mute_for"] as? Bool ?? true
        let useDefaultMuteStories = json["use_default_mute_stories"] as? Bool ?? true
        let useDefaultShowPreview = json["use_default_show_preview"] as? Bool ?? true
        let useDefaultShowStoryPoster = json["use_default_show_story_poster"] as? Bool ?? true
        let _ = json["sound"] as? String // TODO: parse sound?
        let useDefaultSound = json["use_default_sound"] as? Bool ?? true
        let useDefaultStorySound = json["use_default_story_sound"] as? Bool ?? true

        return ChatNotificationSettings(
            disableMentionNotifications: disableMentionNotifications,
            disablePinnedMessageNotifications: disablePinnedMessageNotifications,
            muteFor: muteFor,
            muteStories: muteStories,
            showPreview: showPreview,
            showStoryPoster: showStoryPoster,
            soundId: soundId,
            storySoundId: storySoundId,
            useDefaultDisableMentionNotifications: useDefaultDisableMentionNotifications,
            useDefaultDisablePinnedMessageNotifications: useDefaultDisablePinnedMessageNotifications,
            useDefaultMuteFor: useDefaultMuteFor,
            useDefaultMuteStories: useDefaultMuteStories,
            useDefaultShowPreview: useDefaultShowPreview,
            useDefaultShowStoryPoster: useDefaultShowStoryPoster,
            useDefaultSound: useDefaultSound,
            useDefaultStorySound: useDefaultStorySound
        )
    }

    private static func parseChatAvailableReactions(fromJson json: [String: Any]?) -> ChatAvailableReactions? {
        guard let json = json, let type = json["@type"] as? String else { return nil }
        switch type {
            case "chatAvailableReactionsAll":
                 let maxCount = json["max_reaction_count"] as? Int ?? 11 // Пример
                 return .chatAvailableReactionsAll(.init(maxReactionCount: maxCount))
            case "chatAvailableReactionsSome":
                 let reactionsJson = json["reactions"] as? [[String: Any]] ?? []
                 let reactions = reactionsJson.compactMap(parseReactionType)
                 let maxCount = json["max_reaction_count"] as? Int ?? reactions.count // Пример
                 return .chatAvailableReactionsSome(.init(maxReactionCount: maxCount, reactions: reactions))
            default:
                 print("parseChatAvailableReactions: Неизвестный тип \(type)")
                 return nil
        }
    }
    
    // TODO: Реализовать parseReactionType
    private static func parseReactionType(fromJson json: [String: Any]?) -> ReactionType? {
        // Placeholder
        return nil
    }

    private static func parseVideoChat(fromJson json: [String: Any]?) -> VideoChat? {
        guard let json = json else { return nil }
        // TODO: Извлечь поля VideoChat (group_call_id, has_participants, default_participant_id)
        return VideoChat(
            defaultParticipantId: nil, // TODO
            groupCallId: json["group_call_id"] as? Int ?? 0, // Пример
            hasParticipants: json["has_participants"] as? Bool ?? false // Пример
        )
    }

}

// TODO: Добавить заглушку/реализацию для parseVerificationStatus
private func parseVerificationStatus(fromJson json: [String: Any]?) -> VerificationStatus? {
    // Placeholder
    return nil
}

// TODO: Реализовать парсер для MessageSender
private func parseMessageSender(fromJson json: [String: Any]?) -> MessageSender? {
    guard let json = json, let type = json["@type"] as? String else { return nil }
    switch type {
        case "messageSenderUser":
            guard let userId = json["user_id"] as? Int64 else { return nil }
            return .messageSenderUser(.init(userId: userId))
        case "messageSenderChat":
            guard let chatId = json["chat_id"] as? Int64 else { return nil }
            return .messageSenderChat(.init(chatId: chatId))
        default:
            print("parseMessageSender: Неизвестный тип \(type)")
            return nil
    }
}

@main
class AppDelegate: UIResponder, UIApplicationDelegate {

    var window: UIWindow?
    private var client: TDLibClient?
    private var clientManager: TDLibClientManager?
    private var authService: AuthService?
    private var chatListViewModel: ChatListViewModel?
    private var cancellables = Set<AnyCancellable>()
    var navigationController: UINavigationController?
    private let selectedChatsStore = SelectedChatsStore()
    // Последовательная очередь для обработки обновлений TDLib, чтобы избежать одновременных вызовов receive
    private let tdUpdateQueue = DispatchQueue(label: "tgtd.updates.queue")
    // Защита от повторного/реентрантного рестарта при серии updateAuthorizationState(Closed)
    private var isRestartingAuthFlow = false

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        DebugLogger.shared.log("AppDelegate: Запуск приложения")
        
        // Если клиент уже создан, используем его
        if client == nil {
            DebugLogger.shared.log("AppDelegate: Создание TDLib клиента")
            setupTDLibClient()
        }
        
        DebugLogger.shared.log("AppDelegate: Инициализация сервисов")
        if authService == nil {
            if let client = client {
                authService = AuthService(client: client)
            } else {
                DebugLogger.shared.log("AppDelegate: Ошибка - клиент не инициализирован")
                return false
            }
        }
        
        if chatListViewModel == nil {
            if let client = client {
                chatListViewModel = ChatListViewModel(client: client)
            } else {
                DebugLogger.shared.log("AppDelegate: Ошибка - клиент не инициализирован")
                return false
            }
        }
        
        DebugLogger.shared.log("AppDelegate: Создание контроллеров")
        if let authService = authService, let chatListViewModel = chatListViewModel {
            let authVC = AuthQRController(authService: authService)
            let chatListVC = makeChatSelectionController(viewModel: chatListViewModel)
            let navigationController = UINavigationController()
            navigationController.isNavigationBarHidden = false
            self.navigationController = navigationController

            // Устанавливаем начальный экран в зависимости от состояния авторизации
            Task { @MainActor in
                let isAuthorized = authService.isAuthorized
                self.setInitialStack(nav: navigationController, isAuthorized: isAuthorized, authVC: authVC, chatSelectionVC: chatListVC)
            }
            
            authService.$isAuthorized
                .removeDuplicates()
                .receive(on: DispatchQueue.main)
                .sink { [weak self, navigationController, authVC] isAuthorized in
                    guard let self else { return }
                    self.handleAuthStateChange(isAuthorized: isAuthorized, navigationController: navigationController, authVC: authVC)
                }
                .store(in: &cancellables)
            
            // Если окно уже создано через SceneDelegate, устанавливаем rootViewController
            window?.rootViewController = navigationController
            
#if targetEnvironment(macCatalyst)
            // Перестраиваем системное меню после появления окна
            Task { @MainActor in
                UIMenuSystem.main.setNeedsRebuild()
            }
#endif
            
            // Запускаем проверку состояния авторизации только при начальной загрузке
            Task {
                if !authService.isAuthorized {
                    await authService.checkAuthState()
                }
            }
        } else {
            return false
        }
        
        // ЗАПАСНОЙ ВАРИАНТ: Если SceneDelegate не запустился и окно еще не создано
        if self.window == nil {
            print("AppDelegate: SceneDelegate не запустился, создаем окно вручную")
            let window = UIWindow(frame: UIScreen.main.bounds)
            window.backgroundColor = .black
            window.rootViewController = self.navigationController
            self.window = window
            window.makeKeyAndVisible()
        }
        
        return true
    }

    private func setupTDLibClient() {
        // ВАЖНО: TDLib требует, чтобы receive() вызывался с одного фиксированного потока.
        // В TDLibKit менеджер обычно держит receive-loop внутри себя, поэтому менеджер должен быть единственным на процесс.
        if clientManager == nil {
            clientManager = TDLibClientManager()
        }
        client = clientManager?.createClient(updateHandler: { [weak self] (data: Data, client: TDLibClient) in
            // Гарантируем, что обработка обновлений выполняется последовательно на одной очереди
            self?.tdUpdateQueue.async { [weak self] in
                self?.handleUpdateData(data, client: client)
            }
        })
    }
    
    // Вынесенная обработка данных обновления, выполняется на последовательной очереди
    private func handleUpdateData(_ data: Data, client: TDLibClient) {
        let jsonString = String(data: data, encoding: .utf8) ?? ""
        
        // Пробуем сначала использовать ручной парсинг для известных типов обновлений
        if let update = Update.fromRawJSON(data) {
            self.process(update: update)
            return
        }
        
        // Если ручной парсинг не сработал, пробуем автоматический декодер
        do {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let update = try decoder.decode(TDLibKit.Update.self, from: data)
            self.process(update: update)
        } catch {
            // Проверяем тип ошибки и контент JSON для принятия решения
            let errorDescription = "\(error)"
            
            if let fallbackUpdate = self.makeFallbackUpdate(from: data) {
                self.process(update: fallbackUpdate)
                return
            }
            
            // Пропускаем известные безопасные ошибки
            let safeToPropagateError = (
                jsonString.contains("\"@type\":\"updateFile\"") ||
                jsonString.contains("\"@type\":\"updateConnectionState\"") ||
                // Игнорируем ошибки keyNotFound для chatId
                errorDescription.contains("keyNotFound(CodingKeys(stringValue: \"chatId\"")
            )
            
            if safeToPropagateError {
                DebugLogger.shared.log("AppDelegate: Игнорируем безопасную ошибку декодирования: \(error)")
            } else {
                DebugLogger.shared.log("AppDelegate: Ошибка декодирования обновления: \(error)")
                
                // Для других ошибок проверяем авторизацию
                Task { @MainActor in
                    await self.authService?.checkAuthState()
                }
            }
        }
    }
    
    private func process(update: TDLibKit.Update) {
        // Используем DispatchQueue.main.async для снижения нагрузки от создания тысяч Task
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            // 1. AuthService (критично для логина)
            self.authService?.handleUpdate(update)
            
            // 2. ChatListViewModel
            self.chatListViewModel?.handleUpdate(update)
            
            // 3. Системные уведомления
            if case let TDLibKit.Update.updateFile(fileUpdate) = update {
                NotificationCenter.default.post(name: .tgFileUpdated, object: fileUpdate.file)
            }
            
            // 4. Обработка закрытия (перезапуск)
            if case let TDLibKit.Update.updateAuthorizationState(stateUpdate) = update,
               case .authorizationStateClosed = stateUpdate.authorizationState {
                DebugLogger.shared.log("AppDelegate: Получено состояние Closed")
                guard !self.isRestartingAuthFlow else { return }
                self.restartAuthFlow()
            }
        }
    }
    
    private func makeFallbackUpdate(from data: Data) -> TDLibKit.Update? {
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let type = json["@type"] as? String
        else {
            return nil
        }
        
        switch type {
        case "updateFile":
            guard
                let fileObject = json["file"] as? [String: Any],
                JSONSerialization.isValidJSONObject(fileObject),
                let fileData = try? JSONSerialization.data(withJSONObject: fileObject)
            else {
                return nil
            }
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            guard let file = try? decoder.decode(TDLibKit.File.self, from: fileData) else {
                return nil
            }
            return .updateFile(.init(file: file))
        default:
            return nil
        }
    }

    // Проверка, не происходит ли сейчас смена авторизации
    private func isChangingAuthState() -> Bool {
        // Защита от nil
        guard let service = authService else { 
            print("AppDelegate: authService = nil в isChangingAuthState")
            return false 
        }
        return service.isChangingAuthState
    }
    
    override func buildMenu(with builder: UIMenuBuilder) {
        super.buildMenu(with: builder)
        guard builder.system == .main else { return }
        
        let settingsAction = UIAction(title: "Настройки…") { [weak self] _ in
            self?.showSettings()
        }
        let settingsMenu = UIMenu(title: "", options: .displayInline, children: [settingsAction])
        builder.insertChild(settingsMenu, atStartOfMenu: .application)
    }

    @objc
    func showSettings() {
        guard let nav = navigationController else { return }
        // Если уже открыты настройки, не пушим еще раз
        if nav.topViewController is SettingsViewController { return }
        let settingsVC = SettingsViewController()
        nav.pushViewController(settingsVC, animated: true)
    }

    func showHome() {
        guard let nav = navigationController else { return }
        // Если Home уже в стеке, возвращаемся к нему
        if let homeVC = nav.viewControllers.first(where: { $0 is HomeViewController }) {
            nav.popToViewController(homeVC, animated: true)
        } else {
            nav.setViewControllers([makeHomeController()], animated: true)
        }
    }

    func showChannels() {
        guard let nav = navigationController, let chatListViewModel = chatListViewModel else { return }
        // Если Список уже в стеке, возвращаемся к нему
        if let chatVC = nav.viewControllers.first(where: { $0 is ChatListViewController }) {
            nav.popToViewController(chatVC, animated: true)
        } else {
            nav.setViewControllers([makeChatSelectionController(viewModel: chatListViewModel)], animated: true)
        }
    }

    func logoutFromMenu() {
        guard let authService else {
            print("AppDelegate: authService отсутствует, выход невозможен")
            return
        }
        
        Task {
            await authService.logout()
        }
    }
    
    private func topViewController(base: UIViewController? = nil) -> UIViewController? {
        let baseController = base ?? window?.rootViewController
        
        if let navigationController = baseController as? UINavigationController {
            return topViewController(base: navigationController.visibleViewController)
        }
        
        if let tabController = baseController as? UITabBarController, let selected = tabController.selectedViewController {
            return topViewController(base: selected)
        }
        
        if let presented = baseController?.presentedViewController {
            return topViewController(base: presented)
        }
        
        return baseController
    }

    private func handleAuthStateChange(isAuthorized: Bool, navigationController: UINavigationController, authVC: AuthQRController) {
        if isAuthorized {
            if selectedChatsStore.hasCompletedSelection {
                navigationController.setViewControllers([makeHomeController()], animated: true)
            } else {
                navigationController.setViewControllers([makeChatSelectionController(viewModel: chatListViewModel!)], animated: true)
            }
        } else {
            navigationController.setViewControllers([authVC], animated: true)
        }
    }

    @MainActor
    private func restartAuthFlow() {
        guard !isRestartingAuthFlow else { return }
        isRestartingAuthFlow = true
        defer { isRestartingAuthFlow = false }

        DebugLogger.shared.log("AppDelegate: Пересоздаем TDLib клиент и сервисы после выхода")
        cancellables.removeAll()

        setupTDLibClient()

        guard let client else {
            DebugLogger.shared.log("AppDelegate: Клиент не создан при перезапуске")
            return
        }

        authService = AuthService(client: client)
        chatListViewModel = ChatListViewModel(client: client)

        let authVC = AuthQRController(authService: authService!)
        let chatListVC = makeChatSelectionController(viewModel: chatListViewModel!)

        let nav = navigationController ?? UINavigationController()
        nav.isNavigationBarHidden = false
        navigationController = nav
        window?.rootViewController = nav
        
        Task { @MainActor in
            if authService?.isAuthorized == true {
                if selectedChatsStore.hasCompletedSelection {
                    nav.setViewControllers([makeHomeController()], animated: false)
                } else {
                    nav.setViewControllers([chatListVC], animated: false)
                }
            } else {
                nav.setViewControllers([authVC], animated: false)
            }
        }

        authService?.$isAuthorized
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak nav, weak authVC] isAuthorized in
                guard let self, let nav, let authVC else { return }
                self.handleAuthStateChange(isAuthorized: isAuthorized, navigationController: nav, authVC: authVC)
            }
            .store(in: &cancellables)

        // После logout/restart TDLib может “молчать” некоторое время; принудительно запускаем auth-flow,
        // чтобы гарантированно дойти до запроса QR/пароля.
        Task { [weak self] in
            await self?.authService?.startAuthFlow(force: true)
        }
    }

    private func setInitialStack(nav: UINavigationController, isAuthorized: Bool, authVC: AuthQRController, chatSelectionVC: ChatListViewController) {
        if isAuthorized {
            if selectedChatsStore.hasCompletedSelection {
                nav.setViewControllers([makeHomeController()], animated: false)
            } else {
                nav.setViewControllers([chatSelectionVC], animated: false)
            }
        } else {
            nav.setViewControllers([authVC], animated: false)
        }
    }

    private func makeHomeController() -> UIViewController {
        guard let client else { return UIViewController() }
        return HomeViewController(client: client, selectedChatsStore: selectedChatsStore, openSelection: { [weak self] in
            guard let self, let nav = self.navigationController else { return }
            let selectionVC = self.makeChatSelectionController(viewModel: self.chatListViewModel ?? ChatListViewModel(client: client))
            nav.pushViewController(selectionVC, animated: true)
        }, openSettings: { [weak self] in
            self?.showSettings()
        })
    }

    private func makeChatSelectionController(viewModel: ChatListViewModel) -> ChatListViewController {
        let vc = ChatListViewController(
            viewModel: viewModel,
            selectedChats: Set(selectedChatsStore.load()),
            onSaveSelection: { [weak self] ids in
                guard let self, let nav = self.navigationController else { return }
                self.selectedChatsStore.save(ids: Array(ids))
                self.selectedChatsStore.markCompleted()
                nav.setViewControllers([self.makeHomeController()], animated: true)
            }
        )
        return vc
    }

    // MARK: UISceneSession Lifecycle

    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        config.delegateClass = SceneDelegate.self
        return config
    }

    func application(_ application: UIApplication, didDiscardSceneSessions sceneSessions: Set<UISceneSession>) {
    }
}

// Добавляем недостающие типы
struct ActionBar: Codable {
    let text: String
    let type: String
}

struct PendingJoinRequests: Codable {
    let totalCount: Int
    let userIds: [Int64]
    
    enum CodingKeys: String, CodingKey {
        case totalCount = "total_count"
        case userIds = "user_ids"
    }
}

