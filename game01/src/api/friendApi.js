import { supabase } from './supabaseClient'

const friendshipChannels = new Map()

const friendshipSelect = `
  *,
  requester:profiles!friendships_requester_user_id_fkey (
    id,
    nickname,
    avatar,
    level,
    representative_title
  ),
  addressee:profiles!friendships_addressee_user_id_fkey (
    id,
    nickname,
    avatar,
    level,
    representative_title
  )
`

export function normalizeFriendship(row, currentUserId) {
  const isRequester = row.requester_user_id === currentUserId
  const friendProfile = isRequester ? row.addressee : row.requester

  return {
    id: row.id,
    status: row.status,
    direction: isRequester ? 'outgoing' : 'incoming',
    createdAt: row.created_at,
    updatedAt: row.updated_at,
    friend: {
      id: friendProfile?.id,
      nickname: friendProfile?.nickname || 'Unknown',
      avatar: friendProfile?.avatar || 'default-mafia',
      level: friendProfile?.level || 1,
      title: friendProfile?.representative_title || 'Rookie Mafia',
    },
  }
}

export async function getFriendships(currentUserId) {
  const { data, error } = await supabase
    .from('friendships')
    .select(friendshipSelect)
    .or(`requester_user_id.eq.${currentUserId},addressee_user_id.eq.${currentUserId}`)
    .order('updated_at', { ascending: false })

  if (error) {
    throw new Error('친구 목록을 불러오지 못했습니다.')
  }

  return data
    .filter((row) => !['rejected', 'removed'].includes(row.status))
    .map((row) => normalizeFriendship(row, currentUserId))
}

export async function sendFriendRequest(targetNickname) {
  const { error } = await supabase.rpc('send_friend_request', {
    p_target_nickname: targetNickname.trim(),
  })

  if (error) {
    throw new Error('친구 요청을 보내지 못했습니다.')
  }
}

export async function respondFriendRequest(friendshipId, accept) {
  const { error } = await supabase.rpc('respond_friend_request', {
    p_friendship_id: friendshipId,
    p_accept: accept,
  })

  if (error) {
    throw new Error('친구 요청을 처리하지 못했습니다.')
  }
}

export async function removeFriend(friendshipId) {
  const { error } = await supabase.rpc('remove_friend', {
    p_friendship_id: friendshipId,
  })

  if (error) {
    throw new Error('친구를 삭제하지 못했습니다.')
  }
}

export function subscribeToFriendships(currentUserId, callback) {
  unsubscribeFromFriendships(currentUserId)

  const channel = supabase
    .channel(`friendships-${currentUserId}`)
    .on('postgres_changes', { event: '*', schema: 'public', table: 'friendships' }, (payload) => {
      const requesterId = payload.new?.requester_user_id || payload.old?.requester_user_id
      const addresseeId = payload.new?.addressee_user_id || payload.old?.addressee_user_id

      if (requesterId === currentUserId || addresseeId === currentUserId) {
        callback(payload)
      }
    })
    .subscribe((status) => {
      callback({ type: 'subscription-status', status })
    })

  friendshipChannels.set(currentUserId, channel)

  return () => unsubscribeFromFriendships(currentUserId)
}

function unsubscribeFromFriendships(currentUserId) {
  const channel = friendshipChannels.get(currentUserId)

  if (!channel) {
    return
  }

  friendshipChannels.delete(currentUserId)
  supabase.removeChannel(channel)
}
