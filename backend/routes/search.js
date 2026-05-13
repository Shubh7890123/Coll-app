const express = require('express');
const { supabase, supabaseAdmin } = require('../config/supabase');

const router = express.Router();

/**
 * @route   GET /api/search
 * @desc    Global search with ranking
 * @query   q - search query
 * @query   category - 'top' | 'people' | 'groups' (default: 'top')
 * @query   limit - max results (default: 20)
 * @query   offset - pagination offset (default: 0)
 */
router.get('/', async (req, res) => {
    try {
        const { q, category = 'top', limit = 20, offset = 0 } = req.query;
        const userId = req.user?.id;

        if (!q || q.trim().length === 0) {
            return res.status(400).json({
                success: false,
                message: 'Search query is required'
            });
        }

        // Use Supabase RPC for the search
        const { data, error } = await supabaseAdmin.rpc('global_search', {
            p_query: q.trim(),
            p_user_id: userId,
            p_category: category,
            p_limit: parseInt(limit),
            p_offset: parseInt(offset)
        });

        if (error) {
            console.error('Search error:', error);
            return res.status(500).json({
                success: false,
                message: 'Search failed',
                error: error.message
            });
        }

        // Format results
        const formattedResults = data.map(item => {
            if (item.type === 'user') {
                return {
                    type: 'user',
                    id: item.id,
                    username: item.username,
                    displayName: item.display_name,
                    avatarUrl: item.avatar_url,
                    bio: item.bio,
                    followersCount: item.followers_count,
                    isVerified: item.is_verified,
                    score: item.score,
                    mutualFriendsCount: item.mutual_friends_count,
                    friendshipStatus: item.friendship_status
                };
            } else {
                return {
                    type: 'group',
                    id: item.id,
                    name: item.group_name,
                    description: item.group_description,
                    coverImageUrl: item.cover_image_url,
                    memberCount: item.member_count,
                    isPrivate: item.is_private,
                    category: item.category,
                    isMember: item.is_member,
                    score: item.score
                };
            }
        });

        // Separate by category for 'top' results
        let response = {
            success: true,
            query: q,
            category
        };

        if (category === 'top') {
            response.users = formattedResults.filter(r => r.type === 'user');
            response.groups = formattedResults.filter(r => r.type === 'group');
        } else {
            response.results = formattedResults;
        }

        res.json(response);
    } catch (error) {
        console.error('Search error:', error);
        res.status(500).json({
            success: false,
            message: 'Search failed',
            error: error.message
        });
    }
});

/**
 * @route   GET /api/search/suggestions
 * @desc    Quick autocomplete suggestions
 * @query   q - search query prefix
 * @query   limit - max suggestions (default: 10)
 */
router.get('/suggestions', async (req, res) => {
    try {
        const { q, limit = 10 } = req.query;
        const userId = req.user?.id;

        if (!q || q.trim().length < 2) {
            return res.json({
                success: true,
                suggestions: []
            });
        }

        // Search users with prefix match
        const { data: users, error: userError } = await supabaseAdmin
            .from('profiles')
            .select('id, username, display_name, avatar_url')
            .ilike('username', `${q.trim()}%`)
            .neq('id', userId)
            .limit(parseInt(limit) / 2);

        if (userError) throw userError;

        // Search groups with prefix match
        const { data: groups, error: groupError } = await supabaseAdmin
            .from('groups')
            .select('id, name, cover_image_url, is_private')
            .ilike('name', `${q.trim()}%`)
            .limit(parseInt(limit) / 2);

        if (groupError) throw groupError;

        const suggestions = [
            ...(users || []).map(u => ({
                type: 'user',
                id: u.id,
                username: u.username,
                displayName: u.display_name,
                avatarUrl: u.avatar_url
            })),
            ...(groups || []).map(g => ({
                type: 'group',
                id: g.id,
                name: g.name,
                coverImageUrl: g.cover_image_url,
                isPrivate: g.is_private
            }))
        ];

        res.json({
            success: true,
            query: q,
            suggestions
        });
    } catch (error) {
        console.error('Suggestions error:', error);
        res.status(500).json({
            success: false,
            message: 'Failed to get suggestions',
            error: error.message
        });
    }
});

/**
 * @route   GET /api/search/history
 * @desc    Get user's recent searches
 * @query   limit - max results (default: 20)
 */
router.get('/history', async (req, res) => {
    try {
        const userId = req.user?.id;
        const { limit = 20 } = req.query;

        const { data, error } = await supabaseAdmin
            .from('search_history')
            .select('*')
            .eq('user_id', userId)
            .order('searched_at', { ascending: false })
            .limit(parseInt(limit));

        if (error) throw error;

        res.json({
            success: true,
            history: data || []
        });
    } catch (error) {
        console.error('History error:', error);
        res.status(500).json({
            success: false,
            message: 'Failed to get search history',
            error: error.message
        });
    }
});

/**
 * @route   POST /api/search/history
 * @desc    Save a search to history
 * @body    query - search query
 * @body    resultType - 'user' | 'group'
 * @body    resultId - ID of the result
 */
router.post('/history', async (req, res) => {
    try {
        const userId = req.user?.id;
        const { query, resultType, resultId } = req.body;

        if (!query || !resultType || !resultId) {
            return res.status(400).json({
                success: false,
                message: 'Missing required fields'
            });
        }

        const { data, error } = await supabaseAdmin
            .from('search_history')
            .upsert({
                user_id: userId,
                query: query.trim(),
                result_type: resultType,
                result_id: resultId,
                searched_at: new Date().toISOString()
            }, {
                onConflict: 'user_id,query,result_type,result_id'
            })
            .select()
            .single();

        if (error) throw error;

        res.json({
            success: true,
            history: data
        });
    } catch (error) {
        console.error('Save history error:', error);
        res.status(500).json({
            success: false,
            message: 'Failed to save search history',
            error: error.message
        });
    }
});

/**
 * @route   DELETE /api/search/history/:id
 * @desc    Remove an item from search history
 */
router.delete('/history/:id', async (req, res) => {
    try {
        const userId = req.user?.id;
        const { id } = req.params;

        const { error } = await supabaseAdmin
            .from('search_history')
            .delete()
            .eq('id', id)
            .eq('user_id', userId);

        if (error) throw error;

        res.json({
            success: true,
            message: 'Search history item removed'
        });
    } catch (error) {
        console.error('Delete history error:', error);
        res.status(500).json({
            success: false,
            message: 'Failed to remove search history',
            error: error.message
        });
    }
});

/**
 * @route   DELETE /api/search/history
 * @desc    Clear all search history for user
 */
router.delete('/history', async (req, res) => {
    try {
        const userId = req.user?.id;

        const { error } = await supabaseAdmin
            .from('search_history')
            .delete()
            .eq('user_id', userId);

        if (error) throw error;

        res.json({
            success: true,
            message: 'Search history cleared'
        });
    } catch (error) {
        console.error('Clear history error:', error);
        res.status(500).json({
            success: false,
            message: 'Failed to clear search history',
            error: error.message
        });
    }
});

/**
 * @route   GET /api/search/trending
 * @desc    Get trending searches
 * @query   limit - max results (default: 10)
 */
router.get('/trending', async (req, res) => {
    try {
        const { limit = 10 } = req.query;

        const { data, error } = await supabaseAdmin.rpc('get_trending_searches', {
            p_limit: parseInt(limit)
        });

        if (error) throw error;

        const trending = (data || []).map(item => ({
            type: item.type,
            id: item.id,
            name: item.name,
            avatarUrl: item.avatar_url,
            count: item.count
        }));

        res.json({
            success: true,
            trending
        });
    } catch (error) {
        console.error('Trending error:', error);
        res.status(500).json({
            success: false,
            message: 'Failed to get trending searches',
            error: error.message
        });
    }
});

module.exports = router;
